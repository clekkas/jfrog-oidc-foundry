variable "subscription_id" {
  description = "Subscription that contains the Foundry account."
  type        = string
}

variable "tenant_id" {
  description = "Entra tenant for the subscription. Leave null to use the Azure CLI default."
  type        = string
  default     = null
}

variable "resource_group_name" {
  description = "Resource group that contains the Foundry account."
  type        = string
}

variable "foundry_account_name" {
  description = "Foundry (Microsoft.CognitiveServices/accounts) resource name."
  type        = string
}

variable "foundry_project_name" {
  description = "Foundry project that hosts the agent. The connection must live in this project."
  type        = string
}

variable "connection_name" {
  description = "Active registry connection name used by hosted-agent deployments."
  type        = string
  default     = "jfrog-registry"
}

variable "legacy_connection_name" {
  description = "Previous registry connection retained temporarily for rollback."
  type        = string
  default     = "private-registry"
}

variable "registry_target" {
  description = "HTTPS origin of the registry, e.g. https://yourtrial.jfrog.io."
  type        = string

  validation {
    condition     = startswith(var.registry_target, "https://")
    error_message = "registry_target must be an https:// origin."
  }
}

variable "token_audience" {
  description = "Entra application (client) ID configured as the audience in the registry's OIDC integration."
  type        = string
}

variable "token_endpoint" {
  description = "Token-exchange endpoint, absolute or relative to registry_target. JFrog uses /access/api/v1/oidc/token."
  type        = string
  default     = "/access/api/v1/oidc/token"
}

variable "oidc_provider_name" {
  description = "JFrog OIDC provider name, sent as body.provider_name. Set to null for registries that don't use it (e.g. a Docker Distribution adapter)."
  type        = string
  default     = null
}

variable "extra_body_fields" {
  description = "Additional form fields for the token endpoint. Keys are sent as body.<key>."
  type        = map(string)
  default     = {}
}

variable "import_existing_connection" {
  description = "Adopt the legacy connection that existed before Terraform ownership. No-op once it is in state."
  type        = bool
  default     = false
}
