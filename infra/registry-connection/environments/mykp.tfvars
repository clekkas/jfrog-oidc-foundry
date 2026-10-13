# Contract and project-scoped connection for the mykp agent repository.
subscription_id      = "0e494a0c-e2e6-41f8-8a50-6064d842225e"
tenant_id            = "16b3c013-d300-468d-ac64-7eda0820b6d3"
resource_group_name  = "kaiser-foundry-rg"
foundry_account_name = "kaiser-foundry-resource"
foundry_project_name = "mysecond-project-for-kp"

connection_name        = "jfrog-registry"
legacy_connection_name = "private-registry"
registry_target        = "https://trialndswdc.jfrog.io"
token_audience         = "69500e76-a944-435f-9d97-28822dc29c43"
token_endpoint         = "/access/api/v1/oidc/token"
oidc_provider_name     = "oidc-byor"

jfrog_github_oidc_provider_name = "github-oidc"
jfrog_repository_key            = "byor-demo-docker"

# Adopt the target project's existing active connection. This environment does not
# manage the shared account connection or the legacy project connection.
import_existing_connection       = false
import_existing_jfrog_connection = true
manage_legacy_connection         = false
manage_account_scoped_connection = false