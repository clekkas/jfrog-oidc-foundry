<#
.SYNOPSIS
  Provision the self-hosted GitHub Actions runner (infra/ci-runner, AzAPI) and register
  it with the repository. Re-runnable.

  The runner lives in a VNet with a private endpoint to the Terraform state account and
  outbound-only internet via NAT. No inbound access; management is via az vm run-command.

.EXAMPLE
  ./scripts/setup-runner.ps1
#>
[CmdletBinding()]
param(
    [string]$Repo = 'clekkas/byor-agent',
    [string]$RunnerLabel = 'byor-private',
    [string]$VmSize = 'Standard_B2s_v2',
    # Runner region. Defaults to the RUNNER_LOCATION repo variable, then AZURE_LOCATION.
    # The private endpoint can reach the state account across regions.
    [string]$Location,
    [switch]$AutoApprove
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tfDir = Join-Path $root 'infra\ci-runner'

function Invoke-Checked {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
}

function Get-RepoVar([string]$Name) {
    $v = & gh variable get $Name --repo $Repo 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $v) { throw "GitHub variable $Name not set. Run scripts/bootstrap-github-oidc.ps1 first." }
    $v.Trim()
}

$subscriptionId = Get-RepoVar AZURE_SUBSCRIPTION_ID
$tenantId = Get-RepoVar AZURE_TENANT_ID
$resourceGroup = Get-RepoVar AZURE_RESOURCE_GROUP
if (-not $Location) {
    $Location = (& gh variable get RUNNER_LOCATION --repo $Repo 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $Location) { $Location = Get-RepoVar AZURE_LOCATION }
}
$location = $Location.Trim()
& gh variable set RUNNER_LOCATION --repo $Repo --body $location | Out-Null
$stateAccount = Get-RepoVar RS_STORAGE_ACCOUNT

Write-Host '==> Terraform: runner network + VM (AzAPI, local state)'
$tfArgs = @(
    "-var=subscription_id=$subscriptionId", "-var=tenant_id=$tenantId",
    "-var=resource_group_name=$resourceGroup", "-var=location=$location",
    "-var=state_storage_account_name=$stateAccount", "-var=vm_size=$VmSize"
)
Invoke-Checked terraform @("-chdir=$tfDir", 'init', '-input=false')
Invoke-Checked terraform (@("-chdir=$tfDir", 'plan', '-input=false', '-out=tfplan') + $tfArgs)
if (-not $AutoApprove) {
    $answer = Read-Host 'Apply this plan? (y/N)'
    if ($answer -notmatch '^(y|yes)$') { Write-Host 'Aborted.'; exit 1 }
}
Invoke-Checked terraform @("-chdir=$tfDir", 'apply', '-input=false', 'tfplan')
Remove-Item (Join-Path $tfDir 'tfplan') -ErrorAction SilentlyContinue

$vmName = (& terraform "-chdir=$tfDir" output -raw vm_name)

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
command -v azd >/dev/null || curl -fsSL https://aka.ms/install-azd.sh | bash
id ghrunner >/dev/null 2>&1 || useradd -m -s /bin/bash ghrunner
DIR=/home/ghrunner/actions-runner
mkdir -p "`$DIR" && cd "`$DIR"
if [ -f .runner ]; then ./svc.sh stop || true; ./svc.sh uninstall || true; rm -f .runner .credentials .credentials_rsaparams; fi
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

Write-Host @"

Runner VM : $vmName
Labels    : self-hosted, linux, $RunnerLabel
"@
