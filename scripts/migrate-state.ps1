<#
.SYNOPSIS
  One-time copy of an environment's foundation Terraform state from the OLD backend location
  to the NEW dedicated foundation container, with verification. Never modifies or deletes the source.

  dev default:
    from  container 'tfstate'            key 'registry-connection/byor-demo.tfstate'
    to    container 'foundation-tfstate' key 'registry-connection/dev.tfstate'   (from environments/dev.backend.hcl)

  Requirements
    - Run scripts/bootstrap-github-oidc.ps1 first (it creates the destination container and your role on it).
    - You need data-plane access to BOTH containers (Storage Blob Data Reader on the source container at
      least) and a network path to the storage account (public access is disabled: use a machine in the
      runner VNet or a VPN/peering into it).
    - Freeze the old pipeline first: disable the old repo's foundation workflow so nothing writes the
      source state during or after the copy (README: PRE-CUTOVER checklist).

.EXAMPLE
  ./scripts/migrate-state.ps1 -EnvName dev
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvName,
    [string]$SourceContainer = 'tfstate',
    [string]$SourceKey = 'registry-connection/byor-demo.tfstate',
    # Replace an existing destination blob (a previous attempt or an already-initialised state).
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\_common.ps1"

$cfg = Get-FoundationConfig -Root $root -EnvName $EnvName
$account = $cfg.StateStorageAccount
$destContainer = $cfg.StateContainer
$destKey = Get-HclValue $cfg.BackendPath 'key'
if (-not $account -or -not $destContainer -or -not $destKey) { throw "Incomplete backend config: $($cfg.BackendPath)" }
if ($SourceContainer -eq $destContainer -and $SourceKey -eq $destKey) { throw 'Source and destination are the same blob.' }
Invoke-Az account set --subscription $cfg.SubscriptionId

Write-Host "Source      : $account / $SourceContainer / $SourceKey"
Write-Host "Destination : $account / $destContainer / $destKey"

$tmp = Join-Path ([IO.Path]::GetTempPath()) "foundation-state-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $tmp | Out-Null
$srcFile = Join-Path $tmp 'source.tfstate'
$dstFile = Join-Path $tmp 'dest.tfstate'

function Test-BlobExists([string]$Container, [string]$Name) {
    (Invoke-Az storage blob exists --auth-mode login --account-name $account --container-name $Container --name $Name --query exists -o tsv) -eq 'true'
}

try {
    if (-not (Test-BlobExists $SourceContainer $SourceKey)) { throw "Source blob not found: $SourceContainer/$SourceKey" }
    if ((Test-BlobExists $destContainer $destKey) -and -not $Force) {
        throw "Destination already exists: $destContainer/$destKey. If it is the state you want, do nothing. Otherwise re-run with -Force."
    }

    Write-Host '==> Downloading source state'
    Invoke-Az storage blob download --auth-mode login --account-name $account --container-name $SourceContainer --name $SourceKey --file $srcFile -o none

    $state = Get-Content $srcFile -Raw | ConvertFrom-Json
    if (-not $state.lineage -or $null -eq $state.serial) { throw 'Source is not a valid Terraform state file.' }
    if ($state.resources.Count -eq 0) { throw 'Source state has no resources; refusing to migrate an empty state.' }
    $addresses = $state.resources | ForEach-Object { "$($_.mode).$($_.type).$($_.name)" }
    Write-Host "  terraform $($state.terraform_version), serial $($state.serial), lineage $($state.lineage)"
    Write-Host '  resources:'; $addresses | ForEach-Object { Write-Host "    $_" }

    # Expectations for this stack (see README: PRE-CUTOVER). Warn rather than fail: the plan is the real test.
    foreach ($want in 'managed.azapi_resource.legacy_registry', 'managed.azapi_resource.registry_connection', 'managed.azapi_resource.jfrog_registry') {
        if ($addresses -notcontains $want) { Write-Warning "Not in source state: $want" }
    }

    Write-Host '==> Uploading to destination'
    $upload = @('storage', 'blob', 'upload', '--auth-mode', 'login', '--account-name', $account, '--container-name', $destContainer, '--name', $destKey, '--file', $srcFile, '--no-progress', '-o', 'none')
    if ($Force) { $upload += '--overwrite' }
    Invoke-Az @upload

    Write-Host '==> Verifying destination is byte-identical'
    Invoke-Az storage blob download --auth-mode login --account-name $account --container-name $destContainer --name $destKey --file $dstFile -o none
    $a = (Get-FileHash $srcFile -Algorithm SHA256).Hash
    $b = (Get-FileHash $dstFile -Algorithm SHA256).Hash
    if ($a -ne $b) { throw "Hash mismatch after copy (source $a, destination $b)." }
    Write-Host "  SHA-256 $a (match)"
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host @"

==> State copied. The source blob was left untouched as the rollback copy.

Now verify with a real plan (REQUIRED before merging/applying anything):
  terraform -chdir=infra/registry-connection init -reconfigure -backend-config=environments/$EnvName.backend.hcl
  terraform -chdir=infra/registry-connection state list
  terraform -chdir=infra/registry-connection plan -var-file=environments/$EnvName.tfvars -detailed-exitcode

Expected: state list shows data.azapi_resource.project, azapi_resource.legacy_registry and
azapi_resource.jfrog_registry; plan exits 0 (no changes). See README: PRE-CUTOVER.
"@
