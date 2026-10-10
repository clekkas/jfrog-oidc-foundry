# Foundation state backend (dev). Entra-authenticated; the dedicated container is only
# readable by the foundation identities (see README, "Foundation state isolation").
resource_group_name  = "kaiser-foundry-rg"
storage_account_name = "tfstateb173d2d85c34"
container_name       = "foundation-tfstate"
key                  = "registry-connection/dev.tfstate"
use_azuread_auth     = true
