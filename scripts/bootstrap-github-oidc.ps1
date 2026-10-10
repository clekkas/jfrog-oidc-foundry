<#
.SYNOPSIS
  One-time (re-runnable) bootstrap of the foundation deployment identities for ONE environment.

  Creates or reuses, with no client secrets anywhere:
    - Two Entra apps + service principals, each with a GitHub OIDC federated credential bound
      to a GitHub Environment (not a branch):
        <AppPrefix>-<env>-apply  <- environment foundation-<env>       (write; protected reviewers)
        <AppPrefix>-<env>-plan   <- environment foundation-<env>-plan  (read-only; PR plan + drift)
    - The Terraform state storage account and a DEDICATED foundation state container
    - Container-scoped RBAC so only the foundation identities (and you) can touch foundation state
    - Subscription/project RBAC for the two identities
    - The GitHub Environments, their variables, and (optionally) required reviewers on apply

  Everything is derived from infra/registry-connection/environments/<env>.tfvars and
  <env>.backend.hcl. If the backend file is missing it is written with sensible defaults.

.EXAMPLE
  ./scripts/bootstrap-github-oidc.ps1 -Repo contoso/foundry-platform -EnvName dev -Reviewers alice,contoso/platform-admins
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$EnvName,
    [string]$AppPrefix = 'github-foundry-platform',
    # GitHub users and/or org/team-slug required to approve applies. Mandatory (unless -SkipGitHub or -NoRequiredReviewers).
    # Needs a GitHub plan that supports required reviewers on this repo.
    [string[]]$Reviewers = @(),
    [switch]$PreventSelfReview,
    # Explicit opt-out of required reviewers on the apply environment. Only the main-branch restriction remains,
    # so a push to main that changes infra/registry-connection applies without a human gate.
    [switch]$NoRequiredReviewers,
    [string]$StateStorageAccount,
    [string]$StateContainer = 'foundation-tfstate',
    [string]$TerraformVersion = '1.9.8',
    [string]$RunnerLabel = 'byor-private',
    [switch]$SkipOperatorRole,
    [switch]$SkipGitHub
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\_common.ps1"

# Guards that must hold before anything is created.
if (-not $SkipGitHub -and -not $NoRequiredReviewers -and $Reviewers.Count -eq 0) {
    throw "-Reviewers is required (GitHub users and/or org/team-slug). The apply environment 'foundation-$EnvName' must have required reviewers, and re-running this script without them would clear any set earlier."
}
$visibility = (& gh repo view $Repo --json visibility --jq .visibility 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $visibility) { throw "Cannot read repository '$Repo' with gh. Run 'gh auth login' with admin access to the repo." }
if ($visibility -notin 'PRIVATE', 'INTERNAL') {
    throw "Repository '$Repo' is $visibility. It must be private or internal: pull request code runs on the self-hosted runner, which has a private network path to Terraform state."
}
Write-Host "Repository visibility: $visibility"

$cfg = Get-FoundationConfig -Root $root -EnvName $EnvName
$missing = 'SubscriptionId', 'TenantId', 'ResourceGroup', 'FoundryAccount', 'FoundryProject' | Where-Object { -not $cfg.$_ }
if ($missing) { throw "Missing in $($cfg.TfvarsPath): $($missing -join ', ')" }

$SubscriptionId = $cfg.SubscriptionId
$TenantId = $cfg.TenantId
$ResourceGroup = $cfg.ResourceGroup
$stateRg = if ($cfg.StateResourceGroup) { $cfg.StateResourceGroup } else { $ResourceGroup }
if ($cfg.StateStorageAccount) { $StateStorageAccount = $cfg.StateStorageAccount }
if ($cfg.StateContainer) { $StateContainer = $cfg.StateContainer }
if (-not $StateStorageAccount) {
    $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes("$SubscriptionId/$stateRg/$Repo"))).Replace('-', '').ToLower()
    $StateStorageAccount = "tfstate$($hash.Substring(0, 12))"
}

$applyEnv = "foundation-$EnvName"
$planEnv = "foundation-$EnvName-plan"
$rgId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$projectId = "$rgId/providers/Microsoft.CognitiveServices/accounts/$($cfg.FoundryAccount)/projects/$($cfg.FoundryProject)"

Invoke-Az account set --subscription $SubscriptionId

function Set-RoleAssignment([string]$ObjectId, [string]$PrincipalType, [string]$Role, [string]$Scope) {
    $existing = Invoke-Az role assignment list --assignee $ObjectId --role $Role --scope $Scope --query "[].id" -o tsv
    if ($existing) { Write-Host "  = $Role ($PrincipalType)"; return }
    Invoke-Az role assignment create --assignee-object-id $ObjectId --assignee-principal-type $PrincipalType --role $Role --scope $Scope -o none
    Write-Host "  + $Role ($PrincipalType)"
}

# GitHub may issue ID-based ("immutable") subjects, e.g. repo:owner@123/repo@456:...; use whatever prefix the repo reports.
$subPrefix = & gh api "repos/$Repo/actions/oidc/customization/sub" --jq '.sub_claim_prefix // empty' 2>$null
if ($LASTEXITCODE -ne 0 -or -not $subPrefix) { $subPrefix = "repo:$Repo" }
$subPrefix = $subPrefix.Trim()

function Initialize-Identity([string]$Name, [string]$GitHubEnvironment) {
    Write-Host "==> Entra app '$Name' (OIDC subject: environment:$GitHubEnvironment)"
    $appId = Invoke-Az ad app list --display-name $Name --query "[0].appId" -o tsv
    if (-not $appId) {
        $appId = Invoke-Az ad app create --display-name $Name --sign-in-audience AzureADMyOrg --query appId -o tsv
        Write-Host "  + app $appId"
    } else { Write-Host "  = app $appId" }

    $spId = Invoke-Az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv
    if (-not $spId) {
        $spId = Invoke-Az ad sp create --id $appId --query id -o tsv
        Write-Host "  + service principal $spId"
    } else { Write-Host "  = service principal $spId" }

    $subject = "${subPrefix}:environment:$GitHubEnvironment"
    $fics = Invoke-Az ad app federated-credential list --id $appId -o json | ConvertFrom-Json
    if ($fics | Where-Object { $_.subject -eq $subject }) {
        Write-Host "  = federated credential $subject"
    } else {
        $fic = @{
            name      = "github-$($Repo.Replace('/', '-'))-$GitHubEnvironment$(if ($subPrefix -match '@') { '-ids' })"
            issuer    = 'https://token.actions.githubusercontent.com'
            subject   = $subject
            audiences = @('api://AzureADTokenExchange')
        } | ConvertTo-Json -Compress
        $ficFile = New-TemporaryFile
        Set-Content -Path $ficFile -Value $fic -Encoding utf8
        try { Invoke-Az ad app federated-credential create --id $appId --parameters "@$ficFile" -o none } finally { Remove-Item $ficFile }
        Write-Host "  + federated credential $subject"
    }
    [pscustomobject]@{ AppId = $appId; SpId = $spId }
}

$apply = Initialize-Identity "$AppPrefix-$EnvName-apply" $applyEnv
$plan = Initialize-Identity "$AppPrefix-$EnvName-plan" $planEnv

# ---- Terraform state: dedicated container --------------------------------------
Write-Host "==> State storage '$StateStorageAccount' / container '$StateContainer'"
$saId = & az storage account show -n $StateStorageAccount -g $stateRg --query id -o tsv 2>$null
if (-not $saId) {
    $location = Invoke-Az group show -n $stateRg --query location -o tsv
    $saId = Invoke-Az storage account create -n $StateStorageAccount -g $stateRg -l $location `
        --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 `
        --allow-blob-public-access false --allow-shared-key-access false `
        --tags purpose=terraform-state repo=$Repo --query id -o tsv
    Invoke-Az storage account blob-service-properties update --account-name $StateStorageAccount -g $stateRg --enable-versioning true -o none
    Write-Host "  + created $saId"
} else { Write-Host "  = $saId" }

# Management-plane create: works even when the account's public network access is disabled.
if ((Invoke-Az storage container-rm exists --storage-account $StateStorageAccount -g $stateRg -n $StateContainer --query exists -o tsv) -ne 'true') {
    Invoke-Az storage container-rm create --storage-account $StateStorageAccount -g $stateRg -n $StateContainer -o none
    Write-Host "  + container created"
} else { Write-Host "  = container exists" }
$containerScope = "$saId/blobServices/default/containers/$StateContainer"

if (-not (Test-Path $cfg.BackendPath)) {
    @"
resource_group_name  = "$stateRg"
storage_account_name = "$StateStorageAccount"
container_name       = "$StateContainer"
key                  = "registry-connection/$EnvName.tfstate"
use_azuread_auth     = true
"@ | Set-Content -Path $cfg.BackendPath -Encoding utf8
    Write-Host "  + wrote $($cfg.BackendPath) (commit it)"
}

# ---- RBAC ----------------------------------------------------------------------
Write-Host "==> RBAC: apply identity (write)"
Set-RoleAssignment $apply.SpId 'ServicePrincipal' 'Foundry Project Manager' $projectId
Set-RoleAssignment $apply.SpId 'ServicePrincipal' 'Reader' $rgId
Set-RoleAssignment $apply.SpId 'ServicePrincipal' 'Storage Blob Data Contributor' $containerScope

Write-Host "==> RBAC: plan identity (read-only)"
Set-RoleAssignment $plan.SpId 'ServicePrincipal' 'Reader' $rgId
Set-RoleAssignment $plan.SpId 'ServicePrincipal' 'Storage Blob Data Reader' $containerScope

if (-not $SkipOperatorRole) {
    Write-Host "==> RBAC: you (local terraform / one-time state migration)"
    $me = Invoke-Az ad signed-in-user show --query id -o tsv
    Set-RoleAssignment $me 'User' 'Storage Blob Data Contributor' $containerScope
}

# App repos must not read foundation state. Anything granted blob data roles on the whole
# account can, so list those for review.
Write-Host "==> Review: blob data roles granted at ACCOUNT scope (these principals can read foundation state)"
$wide = Invoke-Az role assignment list --scope $saId --query "[?scope=='$saId' && starts_with(roleDefinitionName,'Storage Blob Data')].{principal:principalName,type:principalType,role:roleDefinitionName}" -o json | ConvertFrom-Json
if ($wide) { $wide | Format-Table -AutoSize | Out-String | Write-Host; Write-Host '  Scope those to their own containers (README: Foundation state isolation).' }
else { Write-Host '  none' }

# ---- GitHub ----------------------------------------------------------------------
function Resolve-Reviewer([string]$Name) {
    if ($Name -match '^(?<org>[^/]+)/(?<slug>.+)$') {
        $id = & gh api "orgs/$($Matches.org)/teams/$($Matches.slug)" --jq .id
        @{ type = 'Team'; id = [int64]$id }
    } else {
        $id = & gh api "users/$Name" --jq .id
        @{ type = 'User'; id = [int64]$id }
    }
}

function Initialize-GitHubEnvironment([string]$Name, [hashtable]$Vars, [bool]$Protected) {
    Write-Host "==> GitHub environment '$Name'"
    $body = @{}
    if ($Protected) {
        $body.deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true }
        # An empty reviewers array is rejected on plans without required reviewers (HTTP 422), so omit the key.
        if (-not $NoRequiredReviewers) {
            $body.reviewers = @($Reviewers | ForEach-Object { Resolve-Reviewer $_ })
            $body.prevent_self_review = [bool]$PreventSelfReview
        }
    } else {
        $body.deployment_branch_policy = $null
    }
    $body | ConvertTo-Json -Depth 5 | & gh api -X PUT "repos/$Repo/environments/$Name" --input - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not create environment $Name (required reviewers need a GitHub plan that supports them on this repo)" }

    if ($Protected) {
        $existing = & gh api "repos/$Repo/environments/$Name/deployment-branch-policies" --jq '.branch_policies[].name'
        if ($existing -notcontains 'main') {
            @{ name = 'main'; type = 'branch' } | ConvertTo-Json | & gh api -X POST "repos/$Repo/environments/$Name/deployment-branch-policies" --input - | Out-Null
        }

        # Read back: fail loudly rather than leave the write identity reachable without approval.
        $envInfo = & gh api "repos/$Repo/environments/$Name" | ConvertFrom-Json
        $reviewerCount = @($envInfo.protection_rules | Where-Object type -eq 'required_reviewers' | ForEach-Object { $_.reviewers }).Count
        if ($NoRequiredReviewers) { Write-Warning "Environment '$Name' has NO required reviewers (-NoRequiredReviewers): a push to main that changes infra/registry-connection applies without approval. Re-run with -Reviewers to restore the gate." }
        elseif ($reviewerCount -lt 1) { throw "Environment '$Name' has no required reviewers after configuration." }
        if (-not $envInfo.deployment_branch_policy.custom_branch_policies) { throw "Environment '$Name' is not restricted to custom deployment branches." }
        $branches = & gh api "repos/$Repo/environments/$Name/deployment-branch-policies" --jq '[.branch_policies[].name] | join(",")'
        Write-Host "  verified: $reviewerCount required reviewer(s); deployment branches: $branches"
        if ($branches -ne 'main') { Write-Warning "Deployment branches for '$Name' are '$branches', expected only 'main'. Remove extras in Settings -> Environments." }
    }
    foreach ($k in $Vars.Keys) {
        & gh variable set $k --repo $Repo --env $Name --body $Vars[$k] | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "gh variable set $k ($Name) failed" }
        Write-Host "  $k = $($Vars[$k])"
    }
}

if (-not $SkipGitHub) {
    Initialize-GitHubEnvironment $applyEnv ([ordered]@{
            AZURE_CLIENT_ID = $apply.AppId; AZURE_TENANT_ID = $TenantId; AZURE_SUBSCRIPTION_ID = $SubscriptionId
        }) $true
    Initialize-GitHubEnvironment $planEnv ([ordered]@{
            AZURE_CLIENT_ID = $plan.AppId; AZURE_TENANT_ID = $TenantId; AZURE_SUBSCRIPTION_ID = $SubscriptionId
        }) $false

    Write-Host "==> GitHub repository variables"
    foreach ($kv in @{ TERRAFORM_VERSION = $TerraformVersion; RUNNER_LABEL = $RunnerLabel }.GetEnumerator()) {
        & gh variable set $kv.Key --repo $Repo --body $kv.Value | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "gh variable set $($kv.Key) failed" }
        Write-Host "  $($kv.Key) = $($kv.Value)"
    }
}

Write-Host @"

==> Done for '$EnvName'.
  apply identity : $AppPrefix-$EnvName-apply  ($($apply.AppId))  <- environment $applyEnv
  plan identity  : $AppPrefix-$EnvName-plan  ($($plan.AppId))  <- environment $planEnv

Next:
  1. Commit infra/registry-connection/environments/$EnvName.backend.hcl if it was just written.
  2. Runner (state account has no public access): ./scripts/setup-runner.ps1 -Repo $Repo -EnvName $EnvName
  3. If this environment already has state in the old location: ./scripts/migrate-state.ps1 -EnvName $EnvName
  4. Work through README: PRE-CUTOVER checklist before the first apply.
"@
