# Isolated state for the mykp Foundry project environment.
resource_group_name  = "kaiser-foundry-rg"
storage_account_name = "tfstateb173d2d85c34"
container_name       = "foundation-tfstate"
key                  = "registry-connection/mykp.tfstate"
use_azuread_auth     = true