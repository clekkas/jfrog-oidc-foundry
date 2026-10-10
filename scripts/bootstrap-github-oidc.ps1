<#
.SYNOPSIS
  One-time (re-runnable) setup for the GitHub Actions deployment pipeline.

  Creates or reuses:
    - Entra app + service principal with a GitHub OIDC federated credential (no client secret)
    - Role assignments: Foundry Project Manager (project), Reader (resource group),
      Storage Blob Data Contributor (state storage) for the pipeline and for you
    - Storage account + container for remote Terraform state (Entra auth only, versioning on)
    - backend.hcl files for local registry-connection and hosted-agent Terraform runs
    - GitHub repository variables consumed by .github/workflows/deploy-agent.yml

  Azure values default to the active azd environment; registry values default to
  infra/registry-connection/terraform.tfvars. Override any of them with parameters.

.EXAMPLE
  ./scripts/bootstrap-github-oidc.ps1
#>
[CmdletBinding()]
param(
    [string]$Repo = 'clekkas/byor-agent',
    [string]$Branch = 'main',
    [string]$AppName = 'github-byor-agent-deployer',
    [string]$SubscriptionId,
    [string]$TenantId,
    [string]$ResourceGroup,
    [string]$Location,
    [string]$FoundryAccount,
    [string]$FoundryProject,
    [string]$EnvName,
    [string]$StateStorageAccount,
    [string]$StateContainer = 'tfstate',
    [string]$JfrogGithubOidcProvider = 'github-oidc',
    [string]$JfrogRepo,
    [string]$TerraformVersion = '1.9.8'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tfDir = Join-Path $root 'infra\registry-connection'
$agentTfDir = Join-Path $root 'infra\hosted-agent'

function Invoke-Az {
    $out = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed" }
    $out
}

function Get-AzdValue([string]$Name) {
    $v = & azd env get-value $Name 2>$null
    if ($LASTEXITCODE -eq 0) { $v.Trim() } else { $null }
}

function Get-TfVar([string]$Name) {
    $file = Join-Path $tfDir 'terraform.tfvars'
    if (-not (Test-Path $file)) { return $null }
    $m = Select-String -Path $file -Pattern "^\s*$Name\s*=\s*`"([^`"]*)`"" | Select-Object -First 1
    if ($m) { $m.Matches[0].Groups[1].Value } else { $null }
}

function Set-RoleAssignment([string]$AssigneeObjectId, [string]$PrincipalType, [string]$Role, [string]$Scope) {
    $existing = Invoke-Az role assignment list --assignee $AssigneeObjectId --role $Role --scope $Scope --query "[].id" -o tsv
    if ($existing) { Write-Host "  = $Role ($PrincipalType) already assigned"; return }
    Invoke-Az role assignment create --assignee-object-id $AssigneeObjectId --assignee-principal-type $PrincipalType --role $Role --scope $Scope -o none
    Write-Host "  + $Role ($PrincipalType)"
}

# ---- Resolve inputs -------------------------------------------------------
Push-Location $root
try {
    if (-not $SubscriptionId) { $SubscriptionId = Get-AzdValue AZURE_SUBSCRIPTION_ID }
    if (-not $TenantId) { $TenantId = Get-AzdValue AZURE_TENANT_ID }
    if (-not $ResourceGroup) { $ResourceGroup = Get-AzdValue AZURE_RESOURCE_GROUP }
    if (-not $Location) { $Location = Get-AzdValue AZURE_LOCATION }
    if (-not $FoundryAccount) { $FoundryAccount = Get-AzdValue AZURE_AI_ACCOUNT_NAME }
    if (-not $FoundryProject) { $FoundryProject = Get-AzdValue AZURE_AI_PROJECT_NAME }
    if (-not $EnvName) { $EnvName = Get-AzdValue AZURE_ENV_NAME }
} finally { Pop-Location }

$registryTarget = Get-TfVar registry_target
$tokenAudience = Get-TfVar token_audience
$tokenEndpoint = Get-TfVar token_endpoint
$registryOidcProvider = Get-TfVar oidc_provider_name
$connectionName = Get-TfVar connection_name
if (-not $connectionName) { $connectionName = 'jfrog-registry' }
if (-not $tokenEndpoint) { $tokenEndpoint = '/access/api/v1/oidc/token' }

if (-not $JfrogRepo) {
    $image = (Select-String -Path (Join-Path $root 'azure.yaml') -Pattern '^\s*image:\s*"?([^"\s]+)"?' | Select-Object -First 1).Matches[0].Groups[1].Value
    $JfrogRepo = $image.Split('/')[1]
}

$required = @{
    SubscriptionId = $SubscriptionId; TenantId = $TenantId; ResourceGroup = $ResourceGroup; Location = $Location
    FoundryAccount = $FoundryAccount; FoundryProject = $FoundryProject; EnvName = $EnvName; JfrogRepo = $JfrogRepo
    registry_target = $registryTarget; token_audience = $tokenAudience; oidc_provider_name = $registryOidcProvider
}
$missing = $required.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object Key
if ($missing) { throw "Missing values: $($missing -join ', '). Pass them as parameters or set them in azd env / terraform.tfvars." }

if (-not $StateStorageAccount) {
    $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes("$SubscriptionId/$ResourceGroup/$Repo"))).Replace('-', '').ToLower()
    $StateStorageAccount = "tfstate$($hash.Substring(0, 12))"
}

$rgId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$projectId = "$rgId/providers/Microsoft.CognitiveServices/accounts/$FoundryAccount/projects/$FoundryProject"
$projectEndpoint = "https://$FoundryAccount.services.ai.azure.com/api/projects/$FoundryProject"
$jfUrl = $registryTarget.TrimEnd('/')

Invoke-Az account set --subscription $SubscriptionId

# ---- Entra app + federated credential ----------------------------------------
Write-Host "==> Entra app '$AppName'"
$appId = Invoke-Az ad app list --display-name $AppName --query "[0].appId" -o tsv
if (-not $appId) {
    $appId = Invoke-Az ad app create --display-name $AppName --sign-in-audience AzureADMyOrg --query appId -o tsv
    Write-Host "  + created app $appId"
} else { Write-Host "  = app $appId" }

$spId = Invoke-Az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv
if (-not $spId) {
    $spId = Invoke-Az ad sp create --id $appId --query id -o tsv
    Write-Host "  + created service principal $spId"
} else { Write-Host "  = service principal $spId" }

# GitHub may issue ID-based ("immutable") subjects, e.g. repo:owner@123/repo@456:...; use whatever prefix the repo reports.
$subPrefix = & gh api "repos/$Repo/actions/oidc/customization/sub" --jq '.sub_claim_prefix // empty' 2>$null
if ($LASTEXITCODE -ne 0 -or -not $subPrefix) { $subPrefix = "repo:$Repo" }
$subject = "$($subPrefix.Trim()):ref:refs/heads/$Branch"
$fics = Invoke-Az ad app federated-credential list --id $appId -o json | ConvertFrom-Json
if ($fics | Where-Object { $_.subject -eq $subject }) {
    Write-Host "  = federated credential for $subject"
} else {
    $fic = @{
        name      = "github-$($Repo.Replace('/', '-'))-$Branch$(if ($subPrefix -match '@') { '-ids' })"
        issuer    = 'https://token.actions.githubusercontent.com'
        subject   = $subject
        audiences = @('api://AzureADTokenExchange')
    } | ConvertTo-Json -Compress
    $ficFile = New-TemporaryFile
    Set-Content -Path $ficFile -Value $fic -Encoding utf8
    try { Invoke-Az ad app federated-credential create --id $appId --parameters "@$ficFile" -o none } finally { Remove-Item $ficFile }
    Write-Host "  + federated credential for $subject"
}

# ---- Terraform state storage ---------------------------------------------------
Write-Host "==> State storage '$StateStorageAccount'"
$saId = & az storage account show -n $StateStorageAccount -g $ResourceGroup --query id -o tsv 2>$null
if (-not $saId) {
    $saId = Invoke-Az storage account create -n $StateStorageAccount -g $ResourceGroup -l $Location `
        --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 `
        --allow-blob-public-access false --allow-shared-key-access false `
        --tags purpose=terraform-state repo=$Repo --query id -o tsv
    Invoke-Az storage account blob-service-properties update --account-name $StateStorageAccount -g $ResourceGroup --enable-versioning true -o none
    Write-Host "  + created $saId"
} else { Write-Host "  = $saId" }

# ---- Role assignments ----------------------------------------------------------
Write-Host '==> Role assignments (pipeline)'
Set-RoleAssignment $spId 'ServicePrincipal' 'Foundry Project Manager' $projectId
Set-RoleAssignment $spId 'ServicePrincipal' 'Reader' $rgId
Set-RoleAssignment $spId 'ServicePrincipal' 'Storage Blob Data Contributor' $saId

Write-Host '==> Role assignments (you, for local terraform with Entra-auth state)'
$me = Invoke-Az ad signed-in-user show --query id -o tsv
Set-RoleAssignment $me 'User' 'Storage Blob Data Contributor' $saId

# Management-plane create: works even though the account's public network access is disabled.
Write-Host "==> Container '$StateContainer'"
if ((Invoke-Az storage container-rm exists --storage-account $StateStorageAccount -g $ResourceGroup -n $StateContainer --query exists -o tsv) -ne 'true') {
    Invoke-Az storage container-rm create --storage-account $StateStorageAccount -g $ResourceGroup -n $StateContainer -o none
    Write-Host '  + created'
} else { Write-Host '  = exists' }

# ---- Local backend config ------------------------------------------------------
$stateKey = "registry-connection/$EnvName.tfstate"
@"
resource_group_name  = "$ResourceGroup"
storage_account_name = "$StateStorageAccount"
container_name       = "$StateContainer"
key                  = "$stateKey"
use_azuread_auth     = true
"@ | Set-Content -Path (Join-Path $tfDir 'backend.hcl') -Encoding utf8
Write-Host "==> Wrote infra/registry-connection/backend.hcl"

$agentStateKey = "hosted-agent/$EnvName.tfstate"
@"
resource_group_name  = "$ResourceGroup"
storage_account_name = "$StateStorageAccount"
container_name       = "$StateContainer"
key                  = "$agentStateKey"
use_azuread_auth     = true
"@ | Set-Content -Path (Join-Path $agentTfDir 'backend.hcl') -Encoding utf8
Write-Host "==> Wrote infra/hosted-agent/backend.hcl"

# ---- GitHub repository variables -------------------------------------------------
Write-Host "==> GitHub variables on $Repo"
$vars = [ordered]@{
    AZURE_CLIENT_ID              = $appId
    AZURE_TENANT_ID              = $TenantId
    AZURE_SUBSCRIPTION_ID        = $SubscriptionId
    AZURE_ENV_NAME               = $EnvName
    AZURE_LOCATION               = $Location
    AZURE_RESOURCE_GROUP         = $ResourceGroup
    FOUNDRY_ACCOUNT_NAME         = $FoundryAccount
    FOUNDRY_PROJECT_NAME         = $FoundryProject
    FOUNDRY_PROJECT_ENDPOINT     = $projectEndpoint
    RS_RESOURCE_GROUP            = $ResourceGroup
    RS_STORAGE_ACCOUNT           = $StateStorageAccount
    RS_CONTAINER_NAME            = $StateContainer
    TF_STATE_KEY                 = $stateKey
    TERRAFORM_VERSION            = $TerraformVersion
    JF_URL                       = $jfUrl
    JFROG_REPO                   = $JfrogRepo
    JFROG_GITHUB_OIDC_PROVIDER   = $JfrogGithubOidcProvider
    JFROG_REGISTRY_CONNECTION_NAME = $connectionName
    REGISTRY_TOKEN_AUDIENCE      = $tokenAudience
    REGISTRY_TOKEN_ENDPOINT      = $tokenEndpoint
    REGISTRY_OIDC_PROVIDER_NAME  = $registryOidcProvider
    # Adopt an existing connection into remote state on first run; no-op afterwards.
    REGISTRY_IMPORT_EXISTING     = 'true'
    RUNNER_LABEL                 = 'byor-private'
}
foreach ($k in $vars.Keys) {
    & gh variable set $k --repo $Repo --body $vars[$k] | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "gh variable set $k failed" }
    Write-Host "  $k = $($vars[$k])"
}

Write-Host @"

==> Done. Remaining manual step in JFrog ($jfUrl):
  Administration > General Management > Manage Integrations > New Integration > OpenID Connect
    Provider type : GitHub
    Provider name : $JfrogGithubOidcProvider
    Provider URL  : https://token.actions.githubusercontent.com
  Identity mapping on that integration:
    Claims JSON   : {"repository":"$Repo","ref":"refs/heads/$Branch"}
    Token scope   : a group/user with Read + Deploy/Cache on the LOCAL repo behind '$JfrogRepo' (e.g. '$JfrogRepo-local')

  The state account has public network access disabled (subscription policy), so the
  deploy job runs on a self-hosted runner: ./scripts/setup-runner.ps1

  If you need to reach state from elsewhere, you need network line of sight to its
  private endpoint (backend.hcl is written for that case).
"@
