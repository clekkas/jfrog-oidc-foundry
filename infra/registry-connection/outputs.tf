output "registry_connection_id" {
  description = "Full resource ID of the active JFrog registry connection."
  value       = azapi_resource.jfrog_registry.id
}

output "registry_connection_name" {
  description = "Active connection name for hosted-agent deployments."
  value       = azapi_resource.jfrog_registry.name
}

output "registry_target" {
  description = "Registry origin approved for hosted-agent image pulls."
  value       = azapi_resource.jfrog_registry.output.properties.target
}

output "legacy_registry_connection_id" {
  description = "Previous connection retained temporarily for rollback."
  value       = azapi_resource.legacy_registry.id
}

output "project_id" {
  description = "Foundry project resource ID."
  value       = data.azapi_resource.project.id
}

output "project_principal_id" {
  description = "Project managed identity object ID. Bind this in the registry's OIDC identity mapping."
  value       = data.azapi_resource.project.output.identity.principalId
}
