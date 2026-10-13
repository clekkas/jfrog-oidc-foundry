<#
.SYNOPSIS
  Provision the self-hosted GitHub Actions runners (infra/ci-runner, AzAPI) and register
  one of them with a repository. Re-runnable.

    infra/ci-runner creates isolated runner VMs for 'foundation', 'agent', and 'mykp'.
    -RunnerKey selects which one is registered to -Repo.

  The state storage account has public network access disabled, so every workflow that touches
  Terraform state runs on a runner. Each lives in a VNet with a private endpoint to the state
  account and outbound-only internet. No inbound access; management is via az vm run-command.

  infra/ci-runner is a bootstrap layer with LOCAL state (git-ignored). Keep that state safe.

.EXAMPLE
  ./scripts/setup-runner.ps1 -Repo contoso/foundry-platform -EnvName dev

.EXAMPLE
  # Runner for the agent repo (second VM, registered to that repo only)
  ./scripts/setup-runner.ps1 -Repo contoso/agent-repo -EnvName dev -RunnerKey agent

    # Runner for the mykp agent repo (third VM, registered to that repo only)
    ./scripts/setup-runner.ps1 -Repo clekkas/jfrog-agent-mykp -EnvName mykp -RunnerKey mykp
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repo,
    # Environment whose tfvars/backend files locate the subscription and state account.
    [Parameter(Mandatory)][string]$EnvName,
    [string]$RunnerLabel = 'byor-private',
    # Which VM of infra/ci-runner registers to -Repo.
    [ValidateSet('foundation', 'agent', 'mykp')][string]$RunnerKey = 'foundation',
    [string]$VmSize = 'Standard_B2s_v2',
    # Defaults to the state resource group's region. The private endpoint can reach the state account across regions.
    [string]$Location,
    [switch]$AutoApprove,
    # Only if you are certain the runner resources do not exist yet (see the state guard below).
    [switch]$AcceptEmptyState
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tfDir = Join-Path $root 'infra\ci-runner'
. "$PSScriptRoot\_common.ps1"

$cfg = Get-FoundationConfig -Root $root -EnvName $EnvName
if (-not $cfg.StateStorageAccount) { throw "No storage_account_name in $($cfg.BackendPath). Run scripts/bootstrap-github-oidc.ps1 first." }
$resourceGroup = if ($cfg.StateResourceGroup) { $cfg.StateResourceGroup } else { $cfg.ResourceGroup }
Invoke-Az account set --subscription $cfg.SubscriptionId

# The runner network may be in a different region than the resource group: reuse wherever it already is.
if (-not $Location) {
    $Location = Invoke-Az resource list -g $resourceGroup --resource-type Microsoft.Network/virtualNetworks --query "[?tags.purpose=='github-actions-runner'].location | [0]" -o tsv
    if (-not $Location) { $Location = Invoke-Az group show -n $resourceGroup --query location -o tsv }
}
$location = $Location.Trim()

# infra/ci-runner keeps LOCAL state, and that file is the only record of the runner resources.
# If it is missing while the runner exists, Terraform would try to recreate everything and fail
# or duplicate. Stop here and recover the file from a backup instead.
$stateFile = Join-Path $tfDir 'terraform.tfstate'
$backupDir = Join-Path $env:USERPROFILE '.foundry-platform\ci-runner-state'
if (-not (Test-Path $stateFile) -and -not $AcceptEmptyState) {
    $existingVm = Invoke-Az resource list -g $resourceGroup --resource-type Microsoft.Compute/virtualMachines --query "[?tags.purpose=='github-actions-runner'].name" -o tsv
    if ($existingVm) {
        throw "No $stateFile, but runner VM '$existingVm' already exists in $resourceGroup. Restore the state file from $backupDir (README: infra/ci-runner local state), or re-import the resources. Use -AcceptEmptyState only if you intend to start over."
    }
}

Write-Host '==> Terraform: runner network + VM (AzAPI, local state)'
$tfArgs = @(
    "-var=subscription_id=$($cfg.SubscriptionId)", "-var=tenant_id=$($cfg.TenantId)",
    "-var=resource_group_name=$resourceGroup", "-var=location=$location",
    "-var=state_storage_account_name=$($cfg.StateStorageAccount)", "-var=vm_size=$VmSize"
)
Invoke-Checked terraform @("-chdir=$tfDir", 'init', '-input=false')
Invoke-Checked terraform (@("-chdir=$tfDir", 'plan', '-input=false', '-out=tfplan') + $tfArgs)
if (-not $AutoApprove) {
    $answer = Read-Host 'Apply this plan? (y/N)'
    if ($answer -notmatch '^(y|yes)$') { Write-Host 'Aborted.'; exit 1 }
}
Invoke-Checked terraform @("-chdir=$tfDir", 'apply', '-input=false', 'tfplan')
Remove-Item (Join-Path $tfDir 'tfplan') -ErrorAction SilentlyContinue

# Timestamped copy outside the repo, so `git clean -x` or a re-clone cannot take the only copy with it.
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$backup = Join-Path $backupDir ("terraform-{0:yyyyMMdd-HHmmss}.tfstate" -f (Get-Date))
Copy-Item $stateFile $backup
Write-Host "==> State backed up to $backup"
Write-Warning 'That file is sensitive and is the only record of the runner. Also keep a copy in a secure location (password manager vault or encrypted backup).'

$vmName = ((& terraform "-chdir=$tfDir" output -json runner_vm_names) | ConvertFrom-Json).$RunnerKey
if (-not $vmName) { throw "No runner VM '$RunnerKey' in infra/ci-runner outputs." }

$runnerName = $vmName
$existing = & gh api "repos/$Repo/actions/runners" --jq ".runners[] | select(.name==`"$runnerName`") | .status"
if ($existing -eq 'online') {
    Write-Host "==> Runner '$runnerName' already registered and online"
} else {
    Write-Host "==> Registering runner '$runnerName' (label: $RunnerLabel)"
    $token = & gh api -X POST "repos/$Repo/actions/runners/registration-token" --jq .token
    if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Could not get a runner registration token.' }

    # Registration token is single-use and expires in 1 hour.
    # run-command executes with /bin/sh (dash): keep this POSIX (no pipefail).
    $script = @"
set -eu
cloud-init status --wait >/dev/null || true
id ghrunner >/dev/null 2>&1 || useradd -m -s /bin/bash ghrunner
DIR=/home/ghrunner/actions-runner
mkdir -p "`$DIR" && cd "`$DIR"
if [ -f .runner ]; then ./svc.sh stop || true; ./svc.sh uninstall || true; fi
rm -f .runner .credentials .credentials_rsaparams .runner_migrated .credentials_migrated .credentials_rsaparams_migrated
if [ ! -f config.sh ]; then
  VER=`$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')
  curl -fsSL -o runner.tgz "https://github.com/actions/runner/releases/download/v`${VER}/actions-runner-linux-x64-`${VER}.tar.gz"
  tar xzf runner.tgz && rm runner.tgz
  ./bin/installdependencies.sh
fi
chown -R ghrunner: "`$DIR"
sudo -u ghrunner ./config.sh --unattended --replace --url https://github.com/$Repo --token $token --name $runnerName --labels $RunnerLabel
./svc.sh install ghrunner
./svc.sh start
echo RUNNER_OK
"@
    $scriptFile = New-TemporaryFile
    Set-Content -Path $scriptFile -Value ($script -replace "`r`n", "`n") -Encoding utf8 -NoNewline
    try {
        $result = & az vm run-command invoke -g $resourceGroup -n $vmName --command-id RunShellScript --scripts "@$scriptFile" --query "value[0].message" -o tsv 2>&1 | Out-String
    } finally { Remove-Item $scriptFile }
    if ($result -notmatch 'RUNNER_OK') { Write-Host ($result -replace [regex]::Escape($token), '***'); throw 'Runner registration failed.' }

    for ($i = 0; $i -lt 12; $i++) {
        $status = & gh api "repos/$Repo/actions/runners" --jq ".runners[] | select(.name==`"$runnerName`") | .status"
        if ($status -eq 'online') { break }
        Start-Sleep 5
    }
    Write-Host "  runner status: $status"
}

& gh variable set RUNNER_LABEL --repo $Repo --body $RunnerLabel | Out-Null

Write-Host @"

Runner VM : $vmName
Labels    : self-hosted, linux, $RunnerLabel
Repo      : $Repo  (use a private/internal repo: PR code runs on this machine)
"@
