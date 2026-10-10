terraform {
  # 1.7+ is required for for_each on import blocks.
  required_version = ">= 1.7.0"

  # Remote state in Azure Storage (Entra auth, OIDC in CI). Settings come from
  # environments/<env>.backend.hcl via -backend-config.
  backend "azurerm" {}

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.13"
    }
  }
}

provider "azapi" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}
