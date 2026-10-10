terraform {
  # 1.7+ is required for for_each on import blocks.
  required_version = ">= 1.7.0"

  # Remote state in Azure Storage (Entra auth). Settings come from backend.hcl
  # locally (written by scripts/bootstrap-github-oidc.ps1) or -backend-config in CI.
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
