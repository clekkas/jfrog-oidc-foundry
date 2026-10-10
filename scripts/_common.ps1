# Shared helpers for the platform scripts. Dot-source: . "$PSScriptRoot\_common.ps1"

function Invoke-Az {
    $out = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed" }
    $out
}

function Invoke-Checked {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
}

# Reads `name = "value"` from a tfvars/backend .hcl file. Returns $null if absent.
function Get-HclValue {
    param([string]$File, [string]$Name)
    if (-not (Test-Path $File)) { return $null }
    $m = Select-String -Path $File -Pattern "^\s*$Name\s*=\s*`"([^`"]*)`"" | Select-Object -First 1
    if ($m) { $m.Matches[0].Groups[1].Value } else { $null }
}

# Single source of truth for an environment: the committed tfvars + backend files.
function Get-FoundationConfig {
    param([string]$Root, [string]$EnvName)
    $dir = Join-Path $Root 'infra\registry-connection\environments'
    $tfvars = Join-Path $dir "$EnvName.tfvars"
    $backend = Join-Path $dir "$EnvName.backend.hcl"
    if (-not (Test-Path $tfvars)) { throw "Missing $tfvars. Copy environments/$EnvName.tfvars.example and fill it in." }
    [pscustomobject]@{
        TfvarsPath          = $tfvars
        BackendPath         = $backend
        SubscriptionId      = Get-HclValue $tfvars 'subscription_id'
        TenantId            = Get-HclValue $tfvars 'tenant_id'
        ResourceGroup       = Get-HclValue $tfvars 'resource_group_name'
        FoundryAccount      = Get-HclValue $tfvars 'foundry_account_name'
        FoundryProject      = Get-HclValue $tfvars 'foundry_project_name'
        StateResourceGroup  = Get-HclValue $backend 'resource_group_name'
        StateStorageAccount = Get-HclValue $backend 'storage_account_name'
        StateContainer      = Get-HclValue $backend 'container_name'
    }
}
