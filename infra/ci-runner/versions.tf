terraform {
  required_version = ">= 1.7.0"

  # Bootstrap layer: local state on the operator's machine (git-ignored). It can't use
  # the private state account it gives the runner access to.

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
