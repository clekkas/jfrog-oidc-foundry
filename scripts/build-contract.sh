#!/usr/bin/env bash
# Build the platform contract for one environment.
#
# Reads the `platform_contract` Terraform output (JSON) on stdin, validates it, and writes
# <output-dir>/foundry-<environment>.json. A markdown summary goes to $GITHUB_STEP_SUMMARY
# (or stdout when run locally).
#
#   terraform -chdir=infra/registry-connection output -json platform_contract \
#     | scripts/build-contract.sh dev contract-out
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <environment> <output-dir>  (platform_contract JSON on stdin)" >&2
  exit 2
fi
environment=$1
out_dir=$2
out_file="$out_dir/foundry-${environment}.json"

# Contract variable names: the legacy single-repo names where they existed.
required='["AZURE_TENANT_ID","AZURE_SUBSCRIPTION_ID","AZURE_RESOURCE_GROUP","FOUNDRY_ACCOUNT_NAME","FOUNDRY_PROJECT_NAME","FOUNDRY_PROJECT_RESOURCE_ID","FOUNDRY_PROJECT_ENDPOINT","FOUNDRY_PROJECT_PRINCIPAL_ID","JFROG_REGISTRY_CONNECTION_NAME","JFROG_REGISTRY_CONNECTION_ID","JF_URL","JFROG_REPO","JFROG_GITHUB_OIDC_PROVIDER","REGISTRY_TOKEN_AUDIENCE","REGISTRY_TOKEN_ENDPOINT","REGISTRY_OIDC_PROVIDER_NAME"]'

values=$(jq -c '{
  AZURE_TENANT_ID:                .tenant_id,
  AZURE_SUBSCRIPTION_ID:          .subscription_id,
  AZURE_RESOURCE_GROUP:           .resource_group_name,
  FOUNDRY_ACCOUNT_NAME:           .foundry_account_name,
  FOUNDRY_PROJECT_NAME:           .foundry_project_name,
  FOUNDRY_PROJECT_RESOURCE_ID:    .foundry_project_resource_id,
  FOUNDRY_PROJECT_ENDPOINT:       .foundry_project_endpoint,
  FOUNDRY_PROJECT_PRINCIPAL_ID:   .foundry_project_principal_id,
  JFROG_REGISTRY_CONNECTION_NAME: .registry_connection_name,
  JFROG_REGISTRY_CONNECTION_ID:   .registry_connection_resource_id,
  JF_URL:                         (.registry_target | rtrimstr("/")),
  JFROG_REPO:                     .jfrog_repository_key,
  JFROG_GITHUB_OIDC_PROVIDER:     .jfrog_github_oidc_provider_name,
  REGISTRY_TOKEN_AUDIENCE:        .registry_token_audience,
  REGISTRY_TOKEN_ENDPOINT:        .registry_token_endpoint,
  REGISTRY_OIDC_PROVIDER_NAME:    .registry_oidc_provider_name
} | with_entries(select(.value != null and .value != ""))')

missing=$(jq -r --argjson req "$required" '$req - keys | join(", ")' <<<"$values")
if [ -n "$missing" ]; then
  echo "::error::Platform contract is missing required values: $missing" >&2
  exit 1
fi

# Digest of the values only (stable key order), so approvers and app repos can confirm
# they are looking at the same contract:  jq -S -c .values foundry-<env>.json | sha256sum
values_sha=$(jq -S -c . <<<"$values" | sha256sum | cut -d' ' -f1)

run_url=""
if [ -n "${GITHUB_RUN_ID:-}" ]; then
  run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi

mkdir -p "$out_dir"
jq -n \
  --arg environment "$environment" \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg repository "${GITHUB_REPOSITORY:-local}" \
  --arg commit "${GITHUB_SHA:-unknown}" \
  --arg workflowRun "$run_url" \
  --arg sha "$values_sha" \
  --argjson values "$values" \
  '{
    contractVersion: "1",
    environment: $environment,
    generatedAt: $generatedAt,
    source: { repository: $repository, commit: $commit, workflowRun: $workflowRun },
    valuesSha256: $sha,
    values: $values
  }' >"$out_file"

{
  echo "## Platform contract: \`${environment}\`"
  echo
  echo "Effective values after this run. Copy them into the app repo's protected GitHub Environment variables (see README)."
  echo
  echo "- Commit: \`${GITHUB_SHA:-unknown}\`"
  echo "- Values SHA-256: \`${values_sha}\`"
  echo "- Artifact: \`platform-contract-${environment}\` (\`foundry-${environment}.json\`)"
  echo
  echo "| Variable | Value |"
  echo "| --- | --- |"
  jq -r 'to_entries[] | "| `\(.key)` | `\(.value)` |"' <<<"$values"
} | if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat >>"$GITHUB_STEP_SUMMARY"; else cat; fi

echo "Wrote $out_file"
