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
  for_each = var.manage_legacy_connection && var.import_existing_connection ? toset([var.legacy_connection_name]) : toset([])
  to       = azapi_resource.legacy_registry[0]
  id       = "${local.project_id}/connections/${each.value}"
}

import {
  for_each = var.import_existing_jfrog_connection ? toset([var.connection_name]) : toset([])
  to       = azapi_resource.jfrog_registry
  id       = "${local.project_id}/connections/${each.value}"
}

moved {
  from = azapi_resource.registry_connection
  to   = azapi_resource.legacy_registry
}

moved {
  from = azapi_resource.legacy_registry
  to   = azapi_resource.legacy_registry[0]
}

moved {
  from = azapi_resource.jfrog_registry_acct
  to   = azapi_resource.jfrog_registry_acct[0]
}

# Retain the previous connection while the new JFrog-specific name is validated.
resource "azapi_resource" "legacy_registry" {
  count     = var.manage_legacy_connection ? 1 : 0
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

    precondition {
      condition     = var.connection_name != var.legacy_connection_name
      error_message = "connection_name and legacy_connection_name must identify different Foundry connections."
    }
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

# POC: account-scoped registry connection, shared to all projects.
resource "azapi_resource" "jfrog_registry_acct" {
  count     = var.manage_account_scoped_connection ? 1 : 0
  type      = "Microsoft.CognitiveServices/accounts/connections@2025-06-01"
  name      = "${var.connection_name}-acct" # -> jfrog-registry-acct
  parent_id = local.account_id

  body = {
    properties = {
      category      = "CustomKeys"
      authType      = "CustomKeys"
      target        = var.registry_target
      isSharedToAll = true
      credentials = {
        keys = local.registry_keys
      }
      metadata = {
        type = "registry_connection"
        mode = "oauth_token_exchange"
      }
    }
  }

  response_export_values = ["properties.target", "properties.metadata", "properties.isSharedToAll"]

  lifecycle {
    prevent_destroy = true
  }
}

# Additional project environments read the account-wide connection owned by dev;
# they must not manage the same Azure resource from multiple Terraform states.
data "azapi_resource" "jfrog_registry_acct" {
  count       = var.manage_account_scoped_connection ? 0 : 1
  type        = "Microsoft.CognitiveServices/accounts/connections@2025-06-01"
  resource_id = "${local.account_id}/connections/${var.connection_name}-acct"

  response_export_values = ["properties.target", "properties.metadata", "properties.isSharedToAll"]
}