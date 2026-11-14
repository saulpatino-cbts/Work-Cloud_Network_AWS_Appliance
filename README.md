# Cloud Network Assessment (CNA) — AWS Appliance

[![Validate](https://github.com/saulpatino-cbts/Work-Cloud_Network_AWS_Appliance/actions/workflows/300-validate.yml/badge.svg)](https://github.com/saulpatino-cbts/Work-Cloud_Network_AWS_Appliance/actions/workflows/300-validate.yml)

This repository deploys and operates the **Cloud Network Assessment platform on AWS**.
It contains the AWS Terraform and the workflows that deploy, update, watch and tear
down an environment — and nothing else. The application itself (web, API, CLI) lives in
the **core** repository, [`Work-Cloud_Network_Core`](https://github.com/saulpatino-cbts/Work-Cloud_Network_Core),
which builds the container images this appliance runs. Features ship once, in those images; this
appliance picks them up.

Its sibling, [`Work-Cloud_Network_Azure_Appliance`](https://github.com/saulpatino-cbts/Work-Cloud_Network_Azure_Appliance), does the same
for Azure. The appliances are intended to share workflow numbers, inputs, release-catalog
contracts and documentation structure, with cloud-specific implementation where needed. Current
parity for the AWS client-target and BYO-AI hardening changes is not verified; `TODO.md` T-115
tracks the Azure/Core contract follow-up. Do not assume the appliance inputs or files are currently
identical.

> **Status:** the AWS Terraform and workflows are authored; local formatting and backend-disabled validation pass. No AWS workflow has been verified against a live customer account. Account/backend/OIDC setup (R-001 – R-003), the required ALB certificate (R-004/R-013), and account-backed permission, approval, and security gates remain in [`REVIEW.md`](REVIEW.md). The initializer prepares client-specific bootstrap resources, but does not establish that GitHub environment protections or effective AWS permissions are correct. Some client deployment inputs and guards are AWS-specific; parity with the Azure appliance is not claimed while T-115 remains open.

---

## What is here, and what is not

| Here | Not here |
|---|---|
| `infra/terraform/` — AWS modules and the `dev` / `prod` environment roots (platform + workload, split state) | Application code — `apps/`, `cna/`, Dockerfiles (core) |
| `.github/workflows/` — bootstrap, validate, deploy, fast redeploy, image update, publish, teardown, drift | Image builds — `200-build-images.yml` (core) |
| `.deployment-catalog/{dev,prod}/` — the release catalog every deploy writes (images, `ai_mode`, evidence) | Anything for Azure |
| `scripts/` — bootstrap and CI evidence helpers | Long-form documentation — the core's [Wiki](https://github.com/saulpatino-cbts/Work-Cloud_Network_Core/wiki) |

### Identical to the sibling, except

| Cloud-specific in this appliance | Here (AWS) | Sibling (Azure) |
|---|---|---|
| Terraform module implementations (`infra/terraform/modules/*`) | ECS Fargate + ALB, RDS PostgreSQL, Secrets Manager, CloudFront + WAF, Bedrock | Container Apps, PostgreSQL Flexible Server, Key Vault, Front Door + WAF, Azure Firewall, AI Foundry |
| Terraform state backend and `000-bootstrap-backend` inputs | `s3` + DynamoDB lock table (`region`, `region_short`, `tfstate_bucket`, `tfstate_lock_table`) | `azurerm`: storage account + container (`location`, `region_short`, `tfstate_resource_group`, `tfstate_storage_account`, `tfstate_container`) |
| CI identity (OIDC) and its secret names | `aws-actions/configure-aws-credentials` — `AWS_DEPLOY_ROLE_ARN` | `azure/login` — `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` |
| Runtime secret store (written by Terraform, read by the tasks) | AWS Secrets Manager | Azure Key Vault |
| Fast redeploy command (`220-fast-redeploy`) | `aws ecs update-service` | `az containerapp update` |
| SaaS AI engine (`ai_mode: saas`) | Amazon Bedrock (`bedrock`) | Azure OpenAI on the AI Foundry account (`azure-openai`) |
| Delivery-portal storage (`320-publish-portal`) | Amazon S3 (private bucket, pre-signed access) | Azure Blob Storage |

The shared contract is intended to cover workflow numbers and names, `210-deploy`'s release
contract, `230-image-update` behavior, the catalog schema, and `README.md`/`CLAUDE.md` structure.
Treat byte identity and matching client-specific inputs as unverified until T-115 is closed.

---

## Documentation map

Four documents plus `CLAUDE.md`; everything long-form is in the core's Wiki.

| Document | Contains |
|---|---|
| `README.md` (this file) | What this appliance is, how to operate it, configuration, conventions |
| [`CHANGELOG.md`](CHANGELOG.md) | Completed work in this repository, by release |
| [`REVIEW.md`](REVIEW.md) | Blockers that require a human decision, approval, or access grant |
| [`TODO.md`](TODO.md) | The engineering work queue for this appliance |
| [`CLAUDE.md`](CLAUDE.md) | Rules for AI coding agents — above all: app code lives in the core, and every structural change is mirrored to the sibling |

---

## Repository layout

```
.github/workflows/
├── 000-bootstrap-backend.yml   Create the Terraform state backend (once per environment)
├── 100-validate-prereqs.yml    Read-only preflight: secrets, variables, identity, registries
├── 210-deploy.yml              Full release or rollback: policy gates → plan → apply → verify
├── 220-fast-redeploy.yml       Image-only rollout for emergencies (does not update the catalog)
├── 230-image-update.yml        Picks up new core images: auto-deploys dev, opens the prod request
├── 300-validate.yml            CI for this repository: secrets scan, docs guard, terraform fmt/validate
├── 320-publish-portal.yml      Publish an engagement's client portal to Amazon S3
├── 330-teardown.yml            Destroy an environment (typed confirmation required)
├── 350-drift-dev.yml           Daily drift detection against the dev release catalog
├── 360-drift-prod.yml          Drift detection for prod (manual until prod exists)
└── 380-project-board.yml       Adds new issues and PRs to the shared project board (inert until core R-012)
.github/ISSUE_TEMPLATE/update-available.md   The prod update request 230 opens
.deployment-catalog/{dev,prod}/              Release catalog: latest.json + one archive per run
infra/terraform/
├── modules/{ai,compute,database,identity,observability,runtime,security,storage}
└── environments/{dev,prod}/{platform,workload}
scripts/                                     ci/ evidence helpers, setup helpers, docs guard
```

---

## Operating the appliance

After the one-time client bootstrap, day-to-day operations are workflow runs from the
**Actions → Run workflow** dialog, in band order. The initializer is an operator-run PowerShell
script and `000` confirms the already-created environment backend.

## Client installation and first deployment

This repository is the customer's deployment repository; it is not the image publisher. Keep
the client deployment identity (`<owner>/<deployment-repo>`) separate from the trusted upstream
image producer (`CORE_OWNER` / `CORE_REPO` and `IMAGE_SIGNING_IDENTITY`). The workflow rejects
missing account, region, backend, image and certificate inputs; replace every angle-bracket
placeholder with a customer-owned value before running a command. Never put passwords, API keys,
tokens or other credentials in workflow inputs, Terraform `-var` arguments, repository variables,
or files.

### Prerequisites and bootstrap

- A distinct customer AWS account for each environment. This draft fails closed if `dev` and
  `prod` share an account, because the current deploy policy is not yet proven least-privilege
  within one account. Choose a Region and a separate state backend for each account, and use an
  administrator who can create the OIDC provider, scoped deploy role, state bucket and lock table.
  The initializer verifies the active AWS identity and requires the other environment's account
  and lock-table names before making changes.
- A dedicated GitHub deployment repository, PowerShell 7, AWS CLI v2, and authenticated `gh`
  with repository administration rights. Use a separate named AWS CLI profile for each account.
- Private Docker Hub pull credentials, an Entra application and the runtime secrets in the
  configuration table below. The core repository owner must provide its actual image-publisher
  identity; the client repository owner is not a substitute.
- For `ai_mode: saas`, select `CNA_BEDROCK_MODEL_ID` for each environment from the current AWS
  Bedrock model/Region documentation. Supply a model ID only when it supports on-demand inference
  in the selected Region; for a profile-only model supply its exact system-defined inference
  profile ARN. The deployment creates an application inference profile from that source by
  default, and the app prefers the created profile ARN over the source ARN. No model ID is
  hard-coded as a client default. Confirm model access and cross-Region implications with the
  account owner before deployment; `210`'s in-environment probe is the live acceptance check.
- An ACM certificate in the deployment account and Region for the ALB. The optional custom domain
  requires a matching CloudFront certificate in `us-east-1`. Without the ALB certificate the
  HTTPS-only CloudFront-to-ALB origin cannot serve requests (502); obtain and validate certificates
  before a deploy. Domain and DNS ownership remain the customer's.

For each target environment, verify the AWS profile/account yourself and preview the initializer
with explicit targets:

```powershell
aws sts get-caller-identity --profile <client-profile>
.\scripts\Initialize-CnaAwsGitHubSecrets.ps1 `
  -Repo "<owner>/<deployment-repo>" -Environment dev `
  -ExpectedAccountId "<12-digit-account-id>" -Region "<aws-region>" `
  -OtherEnvironmentAccountId "<prod-12-digit-account-id>" `
  -OtherEnvironmentLockTable "<prod-lock-table>" `
  -RegionShort "<region-short>" -AwsProfile "<client-profile>" -WhatIf
```

The `-WhatIf` pass still reads the caller identity and may query GitHub/AWS to plan; it does not
apply resource writes. Review its output and the account before rerunning without `-WhatIf`.
Repeat for `prod` with the production account/profile, swapping the dev/prod values for
`-OtherEnvironmentAccountId` and `-OtherEnvironmentLockTable`. Each initializer run records both
accounts and both lock-table names as repository variables
(`CNA_AWS_TARGET_ACCOUNT_ID_DEV`, `CNA_AWS_TARGET_ACCOUNT_ID_PROD`,
`CNA_TFSTATE_LOCK_TABLE_DEV`, `CNA_TFSTATE_LOCK_TABLE_PROD`) and writes that environment's target
and backend settings only to the matching GitHub environment (`dev` or `hub` for prod). Unless
supplied explicitly, the script derives the selected environment's state bucket and lock-table
names from the project, environment, verified account, Region and a stable hash of the deployment
repository. Terraform state keys are also environment-prefixed. For an existing installation,
pass its current bucket/table names explicitly so a default change can never silently point
Terraform at new state. With `-SkipGitHub`, supply both other-environment values and register all
four repository variables through the customer's approved process before running any workflow.

The initializer creates the environment's OIDC role/provider and backend, then prints Terraform
import commands for the role/provider. Run the printed imports from that environment's
`infra/terraform/environments/<env>/workload` root after `terraform init` with that environment's
`TFSTATE_BUCKET`, `TFSTATE_LOCK_TABLE`, Region, and key `<env>/workload.tfstate`; this makes
Terraform adopt the pre-created IAM objects instead of attempting duplicate creates. Run
`000 · Bootstrap Backend` with the same environment, Region, Region short code, bucket and table
to initialize its platform state. A mismatch fails before AWS resource creation.

Before any production run, a repository administrator must configure required reviewers and
deployment-branch restrictions on GitHub's `hub` environment. The workflow's `hub` OIDC subject
is a technical boundary, not a substitute for those GitHub protections. The deploy role trust is
restricted to this deployment repository and its `dev` or `hub` environment, but the live
least-privilege policy still needs account-backed verification; its remaining broad service
actions are listed in `REVIEW.md` R-011. Do not treat the initializer's bootstrap policy as a
production approval.

Repository-level release protections are a separate owner gate. A read-only settings check found
secret scanning and push protection disabled, no repository rulesets, and no branch-protection
record for `main`; organization rulesets and effective organization permissions were not visible
to that query. Do not assume secret scanning, push protection, or direct-push restrictions are
active from these observations. The repository/security admin must confirm inherited policy,
configure the required controls, and verify the effective settings (see `REVIEW.md` R-015).

### Deploy, verify, rollback and cleanup

1. Run `000 · Bootstrap Backend` for the target environment, then `100 · Validate Prerequisites`
   for dev. `AWS_TARGET_ACCOUNT_ID`, `AWS_REGION`, `AWS_REGION_SHORT`, backend variables and
   required secret placeholders must be populated in that GitHub environment. Every AWS workflow
   also requires the repository-level dev/prod account registrations and rejects a missing,
   malformed, mismatched, or shared account configuration before AWS credentials or Terraform
   operations are reached.
2. Run `210 · Deploy` with pinned images. Before each Terraform plan or re-plan, it verifies the
   account/Region and cosign signature plus provenance against `IMAGE_SIGNING_IDENTITY`. The
   signature producer is the core's `200-build-images` workflow, not this client deployment repo.
   Prod applies currently wait on `hub` reviewers, but that approval precedes the post-platform
   workload re-plan; it is not bound to the exact workload plan applied. Production readiness
   remains blocked until this is redesigned and verified (`REVIEW.md` R-017).
3. Confirm the successful run's health/evidence checks and release catalog under
   `.deployment-catalog/<env>/latest.json`; this local evidence is not proof of client live
   readiness until the customer executes it in the target account. After deploying, perform the
   customer's DNS, TLS, authentication and application acceptance checks.
4. Roll back images through `210` with `deploy_mode: rollback` and the previous pinned references
   in the environment's release catalog. This is an application-image rollback, not a general
   infrastructure rollback; review the plan before applying.
5. To tear down an environment, run `330 · Teardown`, type `DESTROY`, review the target and use
   `hub` approval for prod. Keep `destroy_tfstate_backend=false` unless the owner explicitly
   intends to irreversibly remove that environment's versioned backend after preserving any
   required state history. Before backend deletion, the workflow rejects a lock table shared with
   the other environment or one that does not match the repository registration; it also stops if
   bucket deletion fails. Teardown cleanup and backend deletion are AWS mutations and are not run
   by this guide.

### Credential rotation and BYO-AI

Rotate customer credentials at their issuing system, then update the corresponding GitHub secret
or AWS Secrets Manager value using the customer's approved secret-management process; do not
retrieve or print existing secret values. Coordinate a Terraform apply/task restart where a changed
runtime secret must reach ECS, and verify the resulting application health. Historical uploaded
Terraform plan artifacts may contain secret values: deletion and rotation are still explicit
owner actions in `REVIEW.md` R-010; this repository change does not claim either was completed.
`CNA_CREDENTIAL_ENCRYPTION_KEY` is not an ordinary independent rotation: changing it can make
previously encrypted database credentials and BYO-AI keys unreadable. Obtain and follow the Core
owner's supported re-encryption/rotation procedure before changing it; do not rotate it as a
routine response to another secret's rotation.

`byo-api` remains blocked on the security decision in `REVIEW.md` R-006. When approved, configure
`CNA_BYO_AI_PROVIDERS` as a non-empty JSON allowlist such as `["anthropic"]` or
`["anthropic","openai"]`, and set `CNA_AI_ENGINE_DEFAULT` to one of the listed providers. Missing,
malformed, unsupported, duplicate, or inconsistent settings fail Terraform/workflow preflight;
the Terraform default is the empty placeholder `[]`. Existing AWS BYO deployments fail closed in
the app until this variable is configured and the deployment applies it to both `web` and `api`.
This application allowlist does **not** constrain SDK network egress: AWS NAT does not enforce
provider-specific FQDN destinations, so do not claim firewall protection. Enter API keys only on
the application's AI Engine page, never GitHub or Terraform.

### First deploy of an environment

0. **Run `scripts/Initialize-CnaAwsGitHubSecrets.ps1` first** (once per environment, as an AWS account
   admin with your own `aws` and `gh` sessions). Every workflow — including `000` — authenticates
   by assuming the `AWS_DEPLOY_ROLE_ARN` OIDC role, which does **not exist on a cold account**.
   This script    creates the OIDC provider and environment-specific deploy role, state bucket and lock table, the
   `dev`/`prod`/`hub` environments, and writes the secrets/variables the workflows need. `000` is
   then an idempotent confirm-and-converge pass over what the script made — not the true bootstrap.
   (Without this step, `000` fails immediately on "could not assume role". See `REVIEW.md` R-001 – R-003.)
1. **`000 · Bootstrap Backend`** — confirms the isolated Terraform state backend for the environment.
2. **`100 · Validate Prerequisites`** — read-only check that every secret, variable and identity
   the deploy needs is in place. Fix what it reports before going on.
3. **`210 · Deploy`** — `environment: dev` (or `prod`), `deploy_mode: release`, and **`ai_mode`**:
   - **`saas`** — also set the environment variable `CNA_BEDROCK_MODEL_ID` to a customer-selected
     Bedrock model ID that supports on-demand inference in the target Region, or to the exact ARN
     of a system-defined inference profile if the model is profile-only. Terraform creates an
     application inference profile from that source by default; the app invokes its ARN. The
     fallback source ARN is still passed as `CNA_BEDROCK_MODEL_ID`. No model is assumed by this
     repository. Review current [model and inference-profile Region support](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-profiles-support.html)
     and [inference-profile invocation requirements](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-profiles-use.html)
     before configuring. Account model access is still an owner prerequisite.
   - **`byo-api`** — only after Security resolves `REVIEW.md` R-006 and the required non-empty
     `CNA_BYO_AI_PROVIDERS` allowlist includes `CNA_AI_ENGINE_DEFAULT`. **No cloud AI resources
     are provisioned.** After the deploy, an admin opens **AI Engine** in the app and enters keys
     only for the allowlisted Anthropic/OpenAI providers; the core stores them encrypted in the
     database. Existing AWS BYO deployments fail closed until the allowlist is configured and
     applied to both web and api. The allowlist does not restrict outbound SDK traffic through NAT.

   The three image inputs (`api_image`, `web_image`, `migrator_image`) are pinned
   references — `docker.io/<ns>/cna:<role>-sha-<7>@sha256:<digest>` — supplied by `230 · Image
   Update`, or copied from the core's `.deployment-catalog/latest-build.json` (`images.<role>` +
   `digests.<role>`) or from the `update-available` issue. Floating tags (`*-latest`) and tag-only
   references are refused. `prod` applies run under the `hub` environment and wait for its required
   reviewers.

   Before the plan, `210` verifies every image's cosign signature and SLSA provenance against
   `IMAGE_SIGNING_IDENTITY` (the core's `200-build-images` identity); `220` does the same for each
   image it rolls. The verifier accepts cosign's direct statement and DSSE-envelope output while
   enforcing the same image-digest and trusted-builder checks. An image the core did not build and
   sign is refused, whatever its tag says.

On a cold apply, Terraform waits for the API ECS service to reach steady state before creating
the web ECS service that uses its Service Connect name. This reduces the startup race, but does
not prove live DNS propagation or first-request behavior; confirm the first deployment's web logs
and application health in the customer account. The web and API services always keep at least
one task; `210` rolls both to pick up updated secrets (waking either one to a single task if it was
scaled to zero by hand), then waits for service stability.

Flipping `ai_mode` on a live environment destroys or creates the cloud AI resources — record the
decision in `REVIEW.md` first.

### Staying current

**`230 · Image Update`** runs when the core publishes images (`repository_dispatch`) and every six
hours as a safety net. It compares the core's build manifest with `.deployment-catalog/<env>/latest.json`:

- **dev** is redeployed automatically through `210` with the same `ai_mode` it already has
  (`AUTO_UPDATE_DEV` variable, default on).
- **prod** gets an issue labelled `update-available` with the exact image references and a link to
  the `210` dialog. A human runs it; the `hub` approval gate applies.

An environment that has never been deployed is never touched by `230`.

### Everything else

- **Rollback:** `210` with `deploy_mode: rollback` and the three `previous_*_image` references
  from `.deployment-catalog/<env>/latest.json` (or a `<run_id>.json` archive); the migrator comes
  from the same catalog record (`workflow_call` callers may pass `previous_migrator_image`).
- **Emergency image swap:** `220` — fast, but it bypasses Terraform and the catalog; follow with a
  real `210` release.
- **Drift:** `350` (dev, daily) and `360` (prod, manual) plan against the deployed images and
  `ai_mode` from the catalog and warn on differences. A check that *fails* — or finds that the
  environment no longer exists — opens (or updates) one issue assigned to the repository owner.
- **Teardown:** `330` — type `DESTROY`; optionally also destroy the state backend.
- **Client portal:** `320` publishes an engagement's deliverables to Amazon S3.

---

## Configuration

Configuration comes from three places, in this order of authority:

1. **GitHub Secrets and Variables** — the source of truth. Cloud credentials use OIDC; there are
   no long-lived keys. Secrets are never `workflow_dispatch` inputs and never `-var` values.
2. **AWS Secrets Manager** — runtime secrets for a deployed environment, written by Terraform and
   read by the ECS tasks. No workflow exports them; an engineer who needs a value reads it under
   their own IAM identity (`aws secretsmanager get-secret-value`).
3. **The app's AI Engine page** — only the bring-your-own AI API keys, only in `byo-api` mode.

| Kind | Name | Purpose |
|---|---|---|
| Secret | `AWS_DEPLOY_ROLE_ARN` | OIDC deploy role assumed by every workflow |
| Secret | `CNA_AWS_ROLE_ARN`, `CNA_PUBLISH_BUCKET` | Client portal publishing role and bucket identifier (`320`, `dev` environment; separate from the deploy role) |
| Secret | `GH_APP_ID`, `GH_APP_PRIVATE_KEY` | GitHub App used to read the core's build manifest (`230`) and to manage repository variables; installed on the core **and** on this repository (its tokens are scoped to one repository) |
| Secret | `DOCKERHUB_TOKEN` | Pull access for the private `cna` images |
| Secret | `CNA_POSTGRES_ADMIN_PASSWORD`, `CNA_ENTRA_CLIENT_SECRET`, `CNA_NEXTAUTH_SECRET`, `CNA_CREDENTIAL_ENCRYPTION_KEY` | Runtime secrets Terraform writes to AWS Secrets Manager (`100` checks them) |
| Variable | `CORE_OWNER`, `CORE_REPO` | Actual owner and repository of the upstream image publisher; not inferred from the client deployment repository |
| Variable | `IMAGE_SIGNING_IDENTITY` | The upstream core signing identity, `https://github.com/<core-owner>/<core-repo>/.github/workflows/200-build-images.yml@refs/heads/main` — `210` and `220` verify against this trust anchor |
| Variable | `DOCKERHUB_NAMESPACE` | Docker Hub namespace of the `cna` images |
| Variable | `AUTO_UPDATE_DEV` | `false` freezes dev; anything else lets `230` redeploy it |
| Repository variables | `CNA_AWS_TARGET_ACCOUNT_ID_DEV`, `CNA_AWS_TARGET_ACCOUNT_ID_PROD` | Required exact account IDs; all AWS workflows fail before credentials if either is missing, malformed, mismatched, or shared |
| Repository variables | `CNA_TFSTATE_LOCK_TABLE_DEV`, `CNA_TFSTATE_LOCK_TABLE_PROD` | Required distinct lock-table registrations; teardown refuses backend deletion unless the selected table matches its environment and differs from the other |
| Environment variables | `AWS_TARGET_ACCOUNT_ID`, `TFSTATE_BUCKET`, `TFSTATE_LOCK_TABLE`, `AWS_REGION`, `AWS_REGION_SHORT` | Required per `dev` and `hub` environment; `hub` carries prod's separate account, region and isolated backend |
| Variable | `CNA_ENTRA_TENANT_ID`, `CNA_ENTRA_CLIENT_ID`, `CNA_NEXTAUTH_URL` | Environment wiring (the tenant is a variable here because AWS has no Azure OIDC secret to read it from) |
| Variable | `CNA_ALB_CERTIFICATE_ARN` | Required ACM certificate in the target account and deployment region; without it the HTTPS-only origin cannot serve requests |
| Variable | `CNA_CUSTOM_DOMAIN_NAME`, `CNA_CLOUDFRONT_CERTIFICATE_ARN` | Optional together; certificate must be in the same target account and `us-east-1` |
| Variable | `CNA_AZURE_MCP_ENDPOINT`, `CNA_AZURE_MCP_TRANSPORT`, `CNA_AWS_MCP_ENDPOINT`, `CNA_AWS_MCP_TRANSPORT`, `CNA_DRAWIO_MCP_URL` | Optional MCP integrations (transports default to `streamable-http`) |
| Environment variables | `CNA_AI_ENGINE_DEFAULT`, `CNA_BYO_AI_PROVIDERS` | Set in `dev` and `hub` when using BYO; the default engine must be in the non-empty JSON allowlist (e.g. `["anthropic"]`). Empty `[]` is the fail-closed placeholder and is rejected for a BYO plan |
| Environment variable | `CNA_BEDROCK_MODEL_ID` | Required for `ai_mode: saas` in each environment; choose a current Region-supported on-demand model ID or exact system-defined inference-profile ARN. No product/model default is assumed; Terraform validates the input shape and the deployment probe checks live invocation |
| Secret | `PROJECT_BOARD_TOKEN` | Optional: token `380` adds issues and PRs to the shared project board with — the core's `REVIEW.md` R-012 decides which kind; until then `380` is inert |
| Variable | `PROJECT_BOARD_URL` | Optional: the shared GitHub Project, `https://github.com/users/<owner>/projects/<n>`; unset skips `380` entirely |
| Environments | `dev`, `hub` (the script also creates `prod`) | Prod workflows use the protected `hub` environment for its variables, OIDC subject, and required-reviewer gate |

The core's `.env.example` is the complete inventory of every runtime variable the images read.

---

## Repository conventions

- **Four documents plus `CLAUDE.md`, one wiki.** `scripts/validate_documentation_model.py`
  enforces it in `300`. Long-form documentation lives in the core's Wiki.
- **Mirror the sibling.** Any change outside the cloud-specific table above is made in
  [`Work-Cloud_Network_Azure_Appliance`](https://github.com/saulpatino-cbts/Work-Cloud_Network_Azure_Appliance) in the same change set.
  Never introduce Azure content here.
- **Numbered workflows in bands** (`000` bootstrap, `100` validation, `200` deploy/update, `300`
  validate and operations). Numbers are stable across the core and both appliances — never renumber.
- **`.deployment-catalog/` is written by workflows only** (`210` records releases, `230` reads
  them). Never hand-edit it.
- **Never hardcode a value at a call site.** Regions, endpoints and account identifiers are
  declared as Terraform variables and resolved at runtime; variables a human must supply take no
  default.
- **Every GitHub Action is pinned to a SHA digest.** `detect-secrets` fails `300` on any finding not
  in `.secrets.baseline`.

---

*Maintained by CBTS.*
