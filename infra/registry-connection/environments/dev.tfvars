# Inputs for the dev foundation. Committed on purpose: none of these values are secrets
# (the audience is an Entra app ID; the registry issues short-lived tokens via OIDC).
# Changes go through a PR so the foundation-plan workflow shows the effect.

subscription_id      = "0e494a0c-e2e6-41f8-8a50-6064d842225e"
tenant_id            = "16b3c013-d300-468d-ac64-7eda0820b6d3"
resource_group_name  = "kaiser-foundry-rg"
foundry_account_name = "kaiser-foundry-resource"
foundry_project_name = "workshop-demo-project"

connection_name    = "jfrog-registry"
registry_target    = "https://trialndswdc.jfrog.io"
token_audience     = "69500e76-a944-435f-9d97-28822dc29c43"
token_endpoint     = "/access/api/v1/oidc/token"
oidc_provider_name = "oidc-byor"

# Published to app repos through the platform contract (not managed by Terraform).
jfrog_github_oidc_provider_name = "github-oidc"
# Docker repository key in the image path (trialndswdc.jfrog.io/<key>/agent). This is the virtual
# repo; pushes land in its local repo (byor-demo-docker-local). Published as JFROG_REPO.
jfrog_repository_key = "byor-demo-docker"

# Both connections already exist in Foundry. Keeping these imports enabled makes
# an empty or incomplete state adopt them instead of planning duplicate creates.
import_existing_connection        = true
import_existing_jfrog_connection = true
