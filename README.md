# Foundry platform (foundation) repository

This repository owns the **stable foundation** for BYOR hosted agents on Microsoft Foundry:
the connection from a Foundry project to the private JFrog registry, the runner that can reach
the Terraform state, and the identities that deploy them. It publishes a **platform contract**
that application repositories consume.

It does **not** contain application code, a Dockerfile, knowledge files, hosted-agent Terraform,
or agent smoke tests, and it never deploys a hosted-agent version.

> **This repository MUST be private or internal. Never make it public.**
> Pull request workflows run on a **self-hosted runner** that has a private network path to the
> Terraform state storage account and holds a read-only Azure identity. On a public repo,
> anyone could open a PR and run arbitrary code on that machine. `bootstrap-github-oidc.ps1`
> refuses to run against a public repository, and the plan workflow skips fork PRs, but neither
> replaces keeping the repo non-public. Limit write access to trusted platform engineers.

## Ownership boundaries

| Concern | Owner |
| --- | --- |
| Foundry account/project (pre-existing), Foundry-to-JFrog registry connection | **This repo** |
| Foundation Terraform state, state storage account, state RBAC | **This repo** |
| Foundation deployment identities (plan/apply), self-hosted runner | **This repo** |
| JFrog Entra OIDC integration (project managed identity pulls images) | **This repo** (JFrog admin performs the JFrog-side steps) |
| Platform contract (what app repos may rely on) | **This repo** |
| Docker image build, JFrog push (GitHub OIDC), image tags/digests | App repo |
| Hosted-agent version release Terraform, smoke tests | App repo |
| App deployment identity and its RBAC | App repo (granted by platform admins, see below) |

```
platform repo (this)                             app repo
--------------------                             --------
plan  (PR)         read-only identity
apply (main, approval) write identity
   |
   +--> platform contract (summary + artifact) --approved copy--> protected GitHub Environment Variables
                                                                    |
                                                  build image -> push to JFrog -> release hosted agent -> smoke test
```

## Repository layout

```
.github/
  actions/foundation-init/     Composite action: install Terraform, init the remote backend via OIDC
  workflows/
    foundation-plan.yml        PR: fmt, validate, read-only plan per environment
    foundation-apply.yml       main/dispatch: plan -> approval -> apply -> publish contract
    foundation-drift.yml       Scheduled drift detection, opens/closes a GitHub issue
contracts/
  foundry-dev.sample.json      Example of the published contract (placeholder values)
  foundry-prod.sample.json
infra/
  registry-connection/         Foundation Terraform (azapi): JFrog connection + platform_contract output
    environments/              <env>.tfvars (committed, non-secret) and <env>.backend.hcl
  ci-runner/                   Bootstrap layer: VNet, state private endpoint, runner VM (local state)
scripts/
  bootstrap-github-oidc.ps1    Identities, federated credentials, state container, RBAC, GitHub environments
  setup-runner.ps1             Provision and register the self-hosted runner (backs up its local state)
  migrate-state.ps1            One-time, verified copy of foundation state to the new container
  build-contract.sh            Validate the Terraform output and build the contract JSON + summary
  _common.ps1                  Shared helpers
```

## Workflows

All workflows run on the self-hosted runner (label `byor-private`) because the state storage
account has public network access disabled. Authentication is GitHub OIDC to Entra: there are
**no client secrets** anywhere. Terraform's `azurerm` backend uses `use_oidc` and
`use_azuread_auth`, so state access is Entra RBAC only (shared keys are disabled).

| Workflow | Trigger | Identity | Notes |
| --- | --- | --- | --- |
| `foundation-plan` | Pull request touching foundation paths | `foundation-<env>-plan` (read-only) | `terraform fmt -check`, `validate`, `plan` for every environment with an `environments/<env>.tfvars`. Runs with `-lock=false`. |
| `foundation-apply` | Push to `main` (applies `dev`); manual dispatch for `dev` or `prod` (main only) | plan job and contract job: `-plan` identity. apply job: `foundation-<env>` (write) | Saves the plan, waits for the environment's required reviewers, applies **that exact plan**. A stale plan fails and must be re-run. |
| `foundation-drift` | Daily 05:23 UTC and manual | `foundation-<env>-plan` | `plan -detailed-exitcode`. Exit 2 opens or updates a `foundation-drift` issue and fails the run. A clean plan closes it. |

### Platform contract publication

After every successful `foundation-apply` run, including runs with no changes, the `contract`
job reads the live `platform_contract` Terraform output, validates it with
`scripts/build-contract.sh`, and:

1. writes the effective values and their SHA-256 to the **workflow summary**;
2. uploads `foundry-<env>.json` as the **artifact** `platform-contract-<env>` (90 days retention).

See `contracts/foundry-dev.sample.json` for the shape. `values` is a flat map of GitHub
variable names; `valuesSha256` is the digest of `values` with sorted keys, so an approver and an
app repo can confirm they hold the same contract:

```bash
jq -S -c .values foundry-dev.json | sha256sum
```

| Variable | Meaning |
| --- | --- |
| `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_RESOURCE_GROUP` | Where the Foundry project lives |
| `FOUNDRY_ACCOUNT_NAME`, `FOUNDRY_PROJECT_NAME`, `FOUNDRY_PROJECT_RESOURCE_ID`, `FOUNDRY_PROJECT_ENDPOINT` | The Foundry project to release agents into |
| `FOUNDRY_PROJECT_PRINCIPAL_ID` | Project managed identity (the identity that pulls images from JFrog) |
| `JFROG_REGISTRY_CONNECTION_NAME`, `JFROG_REGISTRY_CONNECTION_ID` | The project connection that hosted agents reference |
| `JF_URL` | JFrog base URL (no trailing slash) |
| `JFROG_REPO` | Docker repository key used in image paths (`<JF_URL host>/<JFROG_REPO>/<image>`). Required: `jfrog_repository_key` has no default, and the contract build fails without it |
| `JFROG_GITHUB_OIDC_PROVIDER` | JFrog OIDC provider name app repos use to push from GitHub Actions |
| `REGISTRY_TOKEN_AUDIENCE`, `REGISTRY_TOKEN_ENDPOINT`, `REGISTRY_OIDC_PROVIDER_NAME` | Entra-to-JFrog token exchange settings used by the project identity |

The contract contains identifiers and endpoints only. It contains no secrets and must stay that way.

## How app repos consume the contract

App repos take **approved** values from the contract and store them as **GitHub Environment
variables on a protected environment** in the app repo (for example `dev` and `prod`, with
required reviewers and a branch restriction on `main`). They do not query this repo's state, and
they do not call this repo's workflows.

Process:

1. A platform change merges and `foundation-apply` runs (with reviewer approval).
2. The platform owner opens the run's summary or downloads the `platform-contract-<env>` artifact
   and confirms the values (and `valuesSha256`).
3. A platform or app admin sets each key in `values` as a variable on the app repo's matching
   protected environment, for example:

   ```bash
   jq -r '.values | to_entries[] | [.key, .value] | @tsv' foundry-dev.json |
   while IFS=$'\t' read -r k v; do
     gh variable set "$k" --repo contoso/my-agent --env dev --body "$v"
   done
   ```

4. App workflows read them as `${{ vars.FOUNDRY_PROJECT_ENDPOINT }}`, `${{ vars.JF_URL }}`, etc.

Why environment variables and not repository variables: environment variables are only exposed
to jobs that target that environment, so they inherit its protection rules. Changing the target
Foundry project then requires the same approval as deploying to it.

The app repo's own deployment identity (`AZURE_CLIENT_ID`, and so on) is app-owned and is not
part of the contract.

Contract changes are compatible within `contractVersion` `"1"`: variables may be added, never
renamed or removed. Breaking changes bump the version and are announced to app repo owners.

## App repos must not read foundation Terraform state

Foundation state is not an interface. It is stored in a dedicated container
(`foundation-tfstate`) and contains the full resource definitions, IDs and any values the
provider returns. App repos get what they need from the contract, nothing else.

Enforcement, not just convention:

- State lives in its own container, and `Storage Blob Data Reader`/`Contributor` is granted at
  **container scope** only to the foundation plan and apply identities (and the platform operator).
- Do not grant any app identity a blob data role at storage-account or resource-group scope
  (including `Owner`/`Contributor` plus data-plane roles inherited from above). App repos that
  keep their own Terraform state must use their **own** container, or their own account.
- `bootstrap-github-oidc.ps1` lists any `Storage Blob Data *` assignments at account scope so
  they can be reviewed. Run it again after any RBAC change.
- App workflows must never use `terraform_remote_state` or `data "terraform_remote_state"`
  against this state. Use the contract values instead.

## Required Azure RBAC

Assignments made by `bootstrap-github-oidc.ps1` (names of the identities are
`github-foundry-platform-<env>-apply` and `...-plan`):

| Principal | Role | Scope | Why |
| --- | --- | --- | --- |
| apply identity | `Foundry Project Manager` | Foundry project | Create and update the project's registry connection |
| apply identity | `Reader` | Resource group | Resolve the existing project/account |
| apply identity | `Storage Blob Data Contributor` | State container `foundation-tfstate` | Read/write/lock foundation state |
| plan identity | `Reader` | Resource group | Refresh and plan |
| plan identity | `Storage Blob Data Reader` | State container `foundation-tfstate` | Read state (plans run with `-lock=false`) |
| platform operator (you) | `Storage Blob Data Contributor` | State container | Local runs and one-time state migration. Skip with `-SkipOperatorRole`. |

Also needed, granted once by someone with sufficient rights:

- **To run the bootstrap script:** permission to create Entra apps and service principals,
  and `Owner` or `User Access Administrator` on the resource group and storage account to
  create role assignments.
- **To run `setup-runner.ps1`:** `Contributor` on the resource group (VNet, VM and the
  private endpoint to the state account).
- **Foundry project identity:** image pull authorization is granted on the JFrog side
  (OIDC integration below), not through an Azure role assignment from this repo.
- **App deployment identities** (owned by app repos) need rights on the Foundry project to
  create hosted-agent versions. Grant those from the app side. Caution: the built-in
  `Foundry Project Manager` role can also write project connections, so an app deployer holding
  it could alter the registry connection this repo manages. Prefer a narrower custom role if
  your policy cannot accept that, and rely on drift detection to catch it.

## JFrog prerequisites

Created and owned by a JFrog administrator, outside Terraform:

1. **Entra integration for the Foundry project identity** (the connection's `oidc-byor`
   provider): issuer `https://login.microsoftonline.com/<tenant-id>/v2.0`, audience equal to
   `registry_token_audience` in the tfvars, with an identity mapping for the project managed
   identity (`FOUNDRY_PROJECT_PRINCIPAL_ID`) to a user/group that has **read** permission on the
   Docker repository. Its name must match `registry_oidc_provider_name`.
2. **GitHub OIDC provider** (`github-oidc` by default, `jfrog_github_oidc_provider_name`) with
   issuer `https://token.actions.githubusercontent.com`, and per-app-repo identity mappings
   scoped to the app repo and its protected environment, with **deploy/write** permission on
   the Docker repository only.
3. **A Docker repository** and its key. Set `jfrog_repository_key` in the environment tfvars
   (required); it is published as `JFROG_REPO`. For dev this is the virtual repo
   `byor-demo-docker` (images are `trialndswdc.jfrog.io/byor-demo-docker/agent`); pushes land in
   its local repo `byor-demo-docker-local`, which is where the GitHub provider mapping needs
   deploy permission.
4. **Network reachability:** the JFrog instance must be reachable by Foundry's image pull path
   and by app repo build runners.
5. The JFrog URL in `registry_target` (for example `https://<instance>.jfrog.io`).

This repo only manages the Foundry side (the project connection and the contract). It never
stores JFrog credentials.

## OIDC setup

Two Entra applications per environment, each with a single federated credential bound to a
**GitHub Environment** rather than a branch:

| Identity | Federated subject | GitHub Environment | Protection |
| --- | --- | --- | --- |
| `github-foundry-platform-<env>-apply` | `repo:<owner>/<repo>:environment:foundation-<env>` | `foundation-<env>` | Required reviewers, deploys from `main` only |
| `github-foundry-platform-<env>-plan` | `repo:<owner>/<repo>:environment:foundation-<env>-plan` | `foundation-<env>-plan` | None (read-only) |

This is why PR workflows can plan but can never write: a pull request cannot obtain the apply
identity without the reviewers approving the `foundation-<env>` environment. If the repo uses
immutable (ID-based) OIDC subjects, the script detects the prefix from
`gh api repos/<repo>/actions/oidc/customization/sub` and uses it.

Each environment holds the variables `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and
`AZURE_SUBSCRIPTION_ID` (identifiers, not secrets). Repository variables: `TERRAFORM_VERSION`
and `RUNNER_LABEL`.

### First-time setup

Prerequisites: Azure CLI (logged in), GitHub CLI (authenticated with admin on the repo),
Terraform, PowerShell 7. The repository must be **private or internal** (see the warning at the
top; the bootstrap script enforces it).

```powershell
# 1. Fill in infra/registry-connection/environments/<env>.tfvars (and <env>.backend.hcl).
#    For prod, copy the *.example files first. jfrog_repository_key is required.

# 2. Identities + OIDC federation, state container + container-scoped RBAC, GitHub
#    environments, required reviewers and variables. -Reviewers is mandatory.
./scripts/bootstrap-github-oidc.ps1 -Repo contoso/foundry-platform -EnvName dev `
    -Reviewers alice,contoso/platform-admins -PreventSelfReview

# 3. Private runner with a private endpoint to the state account.
./scripts/setup-runner.ps1 -Repo contoso/foundry-platform -EnvName dev

# 4. Only if state already exists in the old location: verified copy (see "Migrating existing state").
./scripts/migrate-state.ps1 -EnvName dev
```

Then complete the **PRE-CUTOVER checklist** below before the first apply. Both bootstrap scripts
are re-runnable.

What `bootstrap-github-oidc.ps1` guarantees. It fails, rather than continuing, if any of this
cannot be established:

- **Private repo:** refuses to run against a public repository.
- **OIDC federation:** two Entra apps per environment, each with one federated credential whose
  subject is `repo:<owner>/<repo>:environment:<name>`. No client secrets are created.
- **RBAC on the new state container only:** `Storage Blob Data Contributor` (apply) and
  `Storage Blob Data Reader` (plan) on `foundation-tfstate`, not on the storage account. It then
  lists any account-scope `Storage Blob Data *` assignments for review.
- **Reviewers:** `-Reviewers` is mandatory. `foundation-<env>` gets those required reviewers and
  is limited to the `main` deployment branch; the script reads the environment back and fails if
  either is missing. Required reviewers need a GitHub plan that supports them on this repo. `-NoRequiredReviewers` is an explicit, temporary opt-out: only the `main` restriction remains, so a push to `main` that changes `infra/registry-connection/**` applies with no human gate. Re-run with `-Reviewers` to restore it.

### Adding an environment (for example prod)

1. Copy `environments/prod.tfvars.example` to `prod.tfvars` and `prod.backend.hcl.example` to
   `prod.backend.hcl`, then fill them in (use a separate state key, ideally a separate
   subscription and state account). `jfrog_repository_key` is required.
2. Run `bootstrap-github-oidc.ps1 -EnvName prod -Reviewers ...`. The plan, apply and drift
   workflows pick it up automatically.
3. Add a prod JFrog Entra integration and repository as in the prerequisites above.
4. Repeat the PRE-CUTOVER checklist for `prod`.

### Migrating existing state

If the foundation was previously applied from the single-repo setup, its state is in the old
location, and a plan here would see empty state and try to create everything. For dev:

| | Storage account | Container | Key |
| --- | --- | --- | --- |
| Old | `tfstateb173d2d85c34` | `tfstate` | `registry-connection/byor-demo.tfstate` |
| New | `tfstateb173d2d85c34` | `foundation-tfstate` | `registry-connection/dev.tfstate` |

```powershell
./scripts/migrate-state.ps1 -EnvName dev
```

The destination comes from `environments/dev.backend.hcl`; override the source with
`-SourceContainer` / `-SourceKey`. The script refuses an empty or invalid source, refuses to
overwrite an existing destination unless `-Force`, and confirms the copy by SHA-256. It **never
modifies or deletes the source**, which stays as your rollback copy.

It must run from somewhere with a network path to the storage account (public access is
disabled): the runner VM's network, or a VPN/peering into it. You need data-plane access to both
containers. Equivalent manual commands:

```bash
az storage blob download --auth-mode login --account-name tfstateb173d2d85c34 \
  --container-name tfstate --name registry-connection/byor-demo.tfstate --file dev.tfstate
az storage blob upload --auth-mode login --account-name tfstateb173d2d85c34 \
  --container-name foundation-tfstate --name registry-connection/dev.tfstate --file dev.tfstate
rm dev.tfstate
```

Freeze the old pipeline **before** copying so nothing writes the source state mid-migration or
after cutover (two writers means split state). Then verify with `state list` and `plan` as in the
checklist. Delete the old blob only after the new pipeline has been stable for a while.

## infra/ci-runner local state

`infra/ci-runner` provisions the runner that makes the remote state reachable, so it cannot
store its own state in that backend. It keeps **local** state in
`infra/ci-runner/terraform.tfstate`.

- That file is the **only record** of the runner VM, NIC, VNet, NSG, DNS zone and the state
  private endpoint. It contains sensitive values. It is git-ignored on purpose and must never be
  committed.
- **What destroys it:** `git clean -x` / `-fdx`, deleting or re-cloning the folder, or moving to
  another machine without copying it. Run `git clean -n` first and never use `-x` here. The
  `.gitignore` header repeats this warning.
- **Protections in this repo:**
  - `setup-runner.ps1` copies the state after every apply to
    `%USERPROFILE%\.foundry-platform\ci-runner-state\terraform-<timestamp>.tfstate`, outside the repo.
    Treat those files as sensitive.
  - `setup-runner.ps1` refuses to plan when the state file is missing but the runner VM already
    exists (override only with `-AcceptEmptyState`).
  - The VM, VNet and state private endpoint have `prevent_destroy`.
  - Keep one more copy somewhere secure (vault or encrypted backup) and refresh it after every run.
- **Recovery** if the file is lost: copy the newest backup to `infra/ci-runner/terraform.tfstate`
  and run `terraform plan`. With no backup, import each resource by its Azure resource ID
  (`terraform import '<address>' <id>`; addresses are in `main.tf`, the VM is `byor-ci-runner-01`)
  until the plan is clean.
- Losing it does **not** lose foundation state (that lives in the storage account), but a missing
  or broken runner blocks every workflow.

## Workflow security model

- **PR code never gets write credentials.** `foundation-plan` runs PR code, but only with the
  `foundation-<env>-plan` identity (Reader + state Reader). The apply identity's federated
  credential is bound to the `foundation-<env>` environment, which is restricted to the `main`
  deployment branch and requires reviewer approval, so a PR or other branch cannot obtain it.
- **Apply is protected twice.** The `apply` job targets the protected `foundation-<env>`
  environment, and the workflow's `plan` job fails any run not on `refs/heads/main`, so the
  `apply` job never starts. It applies the exact reviewed plan, not a fresh one.
- **Fork PRs are skipped** on the self-hosted runner. Environments hold identifiers only, no secrets.
- **Residual risk (accepted, mitigate where you can):** the runner is persistent and shared by PR
  plan jobs and the privileged apply job. A collaborator with write access could leave something
  on that machine that affects a later apply. Mitigate by keeping write access to trusted
  platform engineers, requiring review on `main` (including changes under `.github/**` and
  `infra/**`, for example via CODEOWNERS), and, as a follow-up, using an ephemeral runner or a
  separate runner label for apply.

## PRE-CUTOVER checklist

Complete every step, in order, before the first apply. Replace `<repo>` with this repository's
`<owner>/<repo>`. Run from the repo root. **Stop at the first unexpected result.** Steps 4 to 6
change Azure/GitHub and need the rights listed under "Required Azure RBAC".

**1. Repository and GitHub**

```bash
gh repo view <repo> --json visibility --jq .visibility
```
Expected: `PRIVATE` or `INTERNAL`. Anything else: stop.

```bash
gh api repos/<repo>/branches/main/protection \
  --jq '{approvals: .required_pull_request_reviews.required_approving_review_count, force_push: .allow_force_pushes.enabled}'
```
Expected: `approvals` of at least 1 and `force_push` false. Also add a CODEOWNERS entry for
`.github/` and `infra/`. (Branch protection and rulesets on private repos need a paid GitHub plan.
If you cannot enable it, record the risk before continuing.)

**2. Configuration (offline)**

```bash
grep -n '^jfrog_repository_key' infra/registry-connection/environments/dev.tfvars
terraform fmt -check -recursive infra
terraform -chdir=infra/registry-connection init -backend=false -input=false
terraform -chdir=infra/registry-connection validate
terraform -chdir=infra/ci-runner init -backend=false -input=false
terraform -chdir=infra/ci-runner validate
```
Expected: `jfrog_repository_key = "byor-demo-docker"`, `fmt` prints nothing, both `validate` print
`Success!`. `jfrog_repository_key` has no default and is validated, so a missing value fails
`plan`; `build-contract.sh` also fails the contract if `JFROG_REPO` is absent.

**3. Freeze the old pipeline** (a setting on the old agent repo, not a code change)

```bash
gh workflow list --repo <old-owner>/<old-agent-repo>
gh workflow disable "<old foundation workflow name or file>" --repo <old-owner>/<old-agent-repo>
gh run list --repo <old-owner>/<old-agent-repo> --status in_progress
```
Expected: the old foundation workflow shows as disabled and nothing is in progress. Re-enable it
only to roll back.

**4. Bootstrap OIDC, RBAC and GitHub environments**

```powershell
./scripts/bootstrap-github-oidc.ps1 -Repo <repo> -EnvName dev -Reviewers <user-or-org/team>[,...] -PreventSelfReview
```
Expected: ends with `Done for 'dev'`, and prints
`verified: N required reviewer(s); deployment branches: main` for `foundation-dev`.
Then verify independently:

```bash
APPLY=$(az ad app list --display-name github-foundry-platform-dev-apply --query "[0].appId" -o tsv)
PLAN=$(az ad app list --display-name github-foundry-platform-dev-plan --query "[0].appId" -o tsv)
az ad app federated-credential list --id "$APPLY" --query "[].subject" -o tsv
az ad app federated-credential list --id "$PLAN" --query "[].subject" -o tsv
az ad app credential list --id "$APPLY" --query "length(@)" -o tsv
az ad app credential list --id "$PLAN" --query "length(@)" -o tsv
```
Expected subjects: `repo:<repo>:environment:foundation-dev` and
`repo:<repo>:environment:foundation-dev-plan` (an ID-based prefix is correct if the repo uses
immutable subjects). Both credential counts `0` (no client secrets).

```bash
SA=$(az storage account show -n tfstateb173d2d85c34 -g kaiser-foundry-rg --query id -o tsv)
az role assignment list --scope "$SA/blobServices/default/containers/foundation-tfstate" \
  --query "[].{who:principalName,role:roleDefinitionName,scope:scope}" -o table
az role assignment list --scope "$SA" \
  --query "[?scope=='$SA' && starts_with(roleDefinitionName,'Storage Blob Data')].{who:principalName,role:roleDefinitionName}" -o table
```
Expected: the first shows the apply identity (`Storage Blob Data Contributor`), the plan identity
(`Storage Blob Data Reader`) and you (`Contributor`), scoped to the `foundation-tfstate` container.
The second shows **nothing**, or only principals you have reviewed and accept can read foundation
state (never an app identity).

```bash
gh api repos/<repo>/environments/foundation-dev \
  --jq '{reviewers: [.protection_rules[] | select(.type=="required_reviewers") | .reviewers[].reviewer | (.login // .slug)], custom_branch_policies: .deployment_branch_policy.custom_branch_policies}'
gh api repos/<repo>/environments/foundation-dev/deployment-branch-policies --jq '[.branch_policies[].name]'
gh variable list --repo <repo> --env foundation-dev
gh variable list --repo <repo> --env foundation-dev-plan
gh variable list --repo <repo>
```
Expected: the reviewers you intended; `custom_branch_policies` true; branches `["main"]`; each
environment has `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`, with a
**different** `AZURE_CLIENT_ID` in `foundation-dev` (apply) and `foundation-dev-plan`; repository
variables `TERRAFORM_VERSION` and `RUNNER_LABEL`.

**5. Runner and its local state**

```powershell
./scripts/setup-runner.ps1 -Repo <repo> -EnvName dev
```
```bash
gh api repos/<repo>/actions/runners --jq '.runners[] | {name, status, labels: [.labels[].name]}'
ls -l infra/ci-runner/terraform.tfstate "$USERPROFILE/.foundry-platform/ci-runner-state/"
```
Expected: the runner is `online` with label `byor-private`; the state file exists and at least one
timestamped backup exists. Copy a backup to a secure second location now.

**6. Migrate state** (from a machine with a network path to the state account)

```powershell
./scripts/migrate-state.ps1 -EnvName dev
```
Expected: lists the source resources, then `SHA-256 <hash> (match)`.

```bash
terraform -chdir=infra/registry-connection init -reconfigure -backend-config=environments/dev.backend.hcl
terraform -chdir=infra/registry-connection state list
terraform -chdir=infra/registry-connection plan -var-file=environments/dev.tfvars -detailed-exitcode; echo "exit=$?"
```
Expected: `state list` includes `data.azapi_resource.project`, `azapi_resource.legacy_registry` and
`azapi_resource.jfrog_registry`; the plan ends with `No changes.` and `exit=0`. Otherwise:

| Result | Meaning | Action |
| --- | --- | --- |
| Plan wants to **create** `jfrog_registry` (or `legacy_registry`) | The connection exists in Azure but not in this state | Add an `import` block for it and re-plan. Do not apply as is: it fails or duplicates. |
| Plan wants to **destroy** or replace anything | Wrong state, wrong tfvars, or drift | **Stop.** Do not apply (`prevent_destroy` also blocks it). |
| In-place update of `body` only | Drift between state and Azure | Review. Fix the tfvars to match Azure, or accept the update deliberately. |
| `Error acquiring the state lock` / `403` | Old pipeline still running, or missing role | Re-check step 3 and your role on the container. |

**7. Contract preview (before CI)**

```bash
terraform -chdir=infra/registry-connection output -json platform_contract \
  | bash scripts/build-contract.sh dev contract-out
jq -r '.values.JFROG_REPO' contract-out/foundry-dev.json
```
Expected: the contract table prints, and the second command prints `byor-demo-docker`. A missing
`JFROG_REPO` fails the build with an error.

**8. First CI run**

1. Open a PR with a harmless change under `infra/registry-connection/` (for example a comment).
   Expected: `foundation-plan` is green and shows `No changes.` for `dev`, and **no** pending
   approval is requested for `foundation-dev` (only the unprotected `foundation-dev-plan`
   environment is used).
2. Prove a branch cannot apply:
   `gh workflow run foundation-apply.yml --repo <repo> --ref <branch> -f environment=dev`.
   Expected: the `plan` job fails with `Foundation apply only runs from main`; the `apply` and
   `contract` jobs do not run.
3. Merge. `foundation-apply` plans on `main`. With no changes the `apply` job is skipped (so the
   reviewer gate is not exercised; step 4 verified its configuration). If there are changes, the
   run pauses for approval; review the plan in the summary, then approve.
4. Verify the contract:
   ```bash
   RUN=$(gh run list --repo <repo> --workflow foundation-apply.yml --limit 1 --json databaseId --jq '.[0].databaseId')
   gh run download "$RUN" --repo <repo> -n platform-contract-dev -D contract-out
   jq -r '.values.JFROG_REPO' contract-out/foundry-dev.json
   test "$(jq -S -c .values contract-out/foundry-dev.json | sha256sum | cut -d' ' -f1)" = "$(jq -r .valuesSha256 contract-out/foundry-dev.json)" && echo sha-ok
   ```
   Expected: `byor-demo-docker`, `sha-ok`, and the same table in the run's workflow summary.
5. Run drift once: `gh workflow run foundation-drift.yml --repo <repo>`. Expected: green, and
   no open `foundation-drift` issue.

**9. Go / no-go**

Cut over only if every expected result above held. **Rollback:** re-enable the old workflow; the
old state blob was never modified. New and old state diverge from the first apply here, so do not
re-enable the old workflow after that without migrating state back. Next: copy the approved
contract values into the app repos' protected environments (see "How app repos consume the
contract").

## Local development

```bash
cd infra/registry-connection
terraform init -backend-config=environments/dev.backend.hcl
terraform plan -var-file=environments/dev.tfvars
terraform output -json platform_contract | ../../scripts/build-contract.sh dev ../../contract-out
```

Requires `Storage Blob Data Contributor` on the state container and network access to it
(the runner, or a VPN into the VNet). `build-contract.sh` needs `jq`.

## Safety notes

- `prevent_destroy` is set on both registry connections, and on the runner VM, VNet and state private endpoint.
- Apply never runs from a pull request, and only from `main`.
- Never commit state, `.tfvars` containing secrets, or `tfplan` files. Plans can contain
  sensitive values and are kept as short-lived artifacts only.
- The drift workflow reports drift but does not fix it. Fix by reverting the out-of-band
  change or by a reviewed PR.
