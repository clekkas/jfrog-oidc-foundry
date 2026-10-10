variable "subscription_id" {
  type = string
}

variable "tenant_id" {
  type    = string
  default = null
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "state_storage_account_name" {
  description = "Terraform state storage account (public network access disabled) to reach via private endpoint."
  type        = string
}

variable "name_prefix" {
  type    = string
  default = "byor-ci"
}

variable "address_space" {
  description = "/24 for the runner VNet. Must not overlap networks you plan to peer."
  type        = string
  default     = "10.250.0.0/24"
}

variable "vm_size" {
  type    = string
  default = "Standard_B2s_v2"
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}
