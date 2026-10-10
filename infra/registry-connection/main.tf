locals {
  account_id = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.CognitiveServices/accounts/${var.foundry_account_name}"
  project_id = "${local.account_id}/projects/${var.foundry_project_name}"

  registry_keys = merge(
    {
      audience      = var.token_audience
      tokenEndpoint = var.token_endpoint
    },
    var.oidc_provider_name == null ? {} : { "body.provider_name" = var.oidc_provider_name },
    { for k, v in var.extra_body_fields : "body.${k}" => v },
  )
}

# The existing Foundry project. Its system-assigned identity is the subject that
# the registry's OIDC integration must trust.
data "azapi_resource" "project" {
  type                   = "Microsoft.CognitiveServices/accounts/projects@2025-06-01"
  resource_id            = local.project_id
  response_export_values = ["identity.principalId", "properties.endpoints"]
}

import {
  for_each = var.import_existing_connection ? toset([var.legacy_connection_name]) : toset([])
  to       = azapi_resource.legacy_registry
  id       = "${local.project_id}/connections/${each.value}"
}

moved {
  from = azapi_resource.registry_connection
  to   = azapi_resource.legacy_registry
}

# Retain the previous connection while the new JFrog-specific name is validated.
resource "azapi_resource" "legacy_registry" {
  type      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01"
  name      = var.legacy_connection_name
  parent_id = data.azapi_resource.project.id

  body = {
    properties = {
      category = "CustomKeys"
      authType = "CustomKeys"
      target   = var.registry_target
      credentials = {
        keys = local.registry_keys
      }
      metadata = {
        type = "registry_connection"
        mode = "oauth_token_exchange"
      }
    }
  }

  response_export_values = ["properties.target", "properties.metadata"]

  lifecycle {
    prevent_destroy = true
  }
}

# Active connection used by the hosted agent.
resource "azapi_resource" "jfrog_registry" {
  type      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01"
  name      = var.connection_name
  parent_id = data.azapi_resource.project.id

  body = {
    properties = {
      category = "CustomKeys"
      authType = "CustomKeys"
      target   = var.registry_target
      credentials = {
        keys = local.registry_keys
      }
      metadata = {
        type = "registry_connection"
        mode = "oauth_token_exchange"
      }
    }
  }

  response_export_values = ["properties.target", "properties.metadata"]

  lifecycle {
    prevent_destroy = true
  }
}
