output "registry_connection_id" {
  description = "Full resource ID of the account-scoped shared JFrog registry connection."
  value       = var.manage_account_scoped_connection ? azapi_resource.jfrog_registry_acct[0].id : data.azapi_resource.jfrog_registry_acct[0].id
}

output "registry_connection_name" {
  description = "Name of the account-scoped shared JFrog registry connection."
  value       = var.manage_account_scoped_connection ? azapi_resource.jfrog_registry_acct[0].name : data.azapi_resource.jfrog_registry_acct[0].name
}

output "registry_target" {
  description = "Registry origin approved for hosted-agent image pulls."
  value       = var.manage_account_scoped_connection ? azapi_resource.jfrog_registry_acct[0].output.properties.target : data.azapi_resource.jfrog_registry_acct[0].output.properties.target
}

output "project_registry_connection_id" {
  description = "Resource ID of the project-scoped registry connection."
  value       = azapi_resource.jfrog_registry.id
}

output "legacy_registry_connection_id" {
  description = "Previous connection retained temporarily for rollback."
  value       = var.manage_legacy_connection ? azapi_resource.legacy_registry[0].id : null
}

output "project_id" {
  description = "Foundry project resource ID."
  value       = data.azapi_resource.project.id
}

output "project_principal_id" {
  description = "Project managed identity object ID. Bind this in the registry's OIDC identity mapping."
  value       = data.azapi_resource.project.output.identity.principalId
}

# Source of truth for the platform contract. scripts/build-contract.sh maps this
# object to the GitHub Environment variables that app repos consume.
output "platform_contract" {
  description = "Values app repos are approved to consume. Contains no secrets."
  value = {
    tenant_id                       = var.tenant_id
    subscription_id                 = var.subscription_id
    resource_group_name             = var.resource_group_name
    foundry_account_name            = var.foundry_account_name
    foundry_project_name            = var.foundry_project_name
    foundry_project_resource_id     = data.azapi_resource.project.id
    foundry_project_endpoint        = "https://${var.foundry_account_name}.services.ai.azure.com/api/projects/${var.foundry_project_name}"
    foundry_project_principal_id    = data.azapi_resource.project.output.identity.principalId
    registry_connection_name        = var.manage_account_scoped_connection ? azapi_resource.jfrog_registry_acct[0].name : data.azapi_resource.jfrog_registry_acct[0].name
    registry_connection_resource_id = var.manage_account_scoped_connection ? azapi_resource.jfrog_registry_acct[0].id : data.azapi_resource.jfrog_registry_acct[0].id
    registry_target                 = var.manage_account_scoped_connection ? azapi_resource.jfrog_registry_acct[0].output.properties.target : data.azapi_resource.jfrog_registry_acct[0].output.properties.target
    registry_token_audience         = var.token_audience
    registry_token_endpoint         = var.token_endpoint
    registry_oidc_provider_name     = var.oidc_provider_name
    jfrog_github_oidc_provider_name = var.jfrog_github_oidc_provider_name
    jfrog_repository_key            = var.jfrog_repository_key
  }
}
