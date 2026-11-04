# Review — human-resolvable blockers

This file tracks **only** items that an engineer cannot resolve independently. Every entry
requires external input: an approval, a credential, an account, an access grant, or a decision
that belongs to a named owner outside the engineering task itself.

Anything an engineer can solve without external input belongs in [`TODO.md`](TODO.md), not here.
Application-level blockers live in the core repository's `REVIEW.md`.

**Last reviewed:** 2026-11-04

| ID | Blocker | Owner | Status |
|---|---|---|---|
| [R-001](#r-001--aws-account-and-administrative-access) | AWS account + administrative access for the first deploy | AWS account owner | Open |
| [R-002](#r-002--terraform-s3-state-backend-created-out-of-band) | Per-environment Terraform S3 state bucket + DynamoDB lock table | AWS account owner | Open |
| [R-003](#r-003--github-oidc-deploy-role-wired-into-ci) | Environment-scoped GitHub OIDC deploy roles | Repository admin | Open |
| [R-004](#r-004--acm-certificates-and-custom-domain-decision) | Required ALB ACM certificate + optional custom-domain decision | DNS / domain owner | Open |
| [R-005](#r-005--amazon-bedrock-model-access-opt-in) | Region-supported Bedrock model/profile and account access (`ai_mode: saas`) | AWS account owner | Open — explicit model input added; target account/Region access remains unverified |
| [R-006](#r-006--security-review-before-the-first-byo-api-deploy) | Security review of the bring-your-own AI key path and provider egress | Security | Open — before the first `byo-api` deploy |
| [R-007](#r-007--required-reviewers-on-the-hub-environment) | `hub` environment required reviewers for prod applies | Repository admin | Open |

| [R-008](#r-008--runtime-secrets-have-no-defaults-and-must-be-supplied) | Runtime secrets supplied at apply time | Security / secret owner | Open |
| [R-009](#r-009--repoint-core_repo-at-the-new-core-repository) | Verify Core repository variables and GitHub App installation | Repository admin | Open — current settings and App installation not verified |
| [R-010](#r-010--rotate-secrets-that-reached-uploaded-terraform-plan-artifacts) | Delete the uploaded `tfplan-*` artifacts (they carried `TF_VAR_*` secret values) and rotate | Security / secret owner | Open — no live environment yet, artifacts still to delete |
| [R-011](#r-011--deploy-role-retains-broad-service-permissions) | Remaining broad deploy-role service actions and account-backed least-privilege verification | AWS account owner | Open — trust/state scopes narrowed locally; broad service actions still need evidence-led review |
| [R-012](#r-012--object-storage-for-the-aws-appliance) | Core web/API storage code is Azure-Blob-only; AWS has no document upload or client portal | Product owner | Open — decides AWS 1.0 scope |
| [R-013](#r-013--the-alb-has-no-https-listener-until-r-004-is-decided) | CloudFront → ALB is `https-only` but the HTTPS listener is `count = 0` without a certificate | DNS / domain owner | Open — every request 502s until R-004 |
| [R-014](#r-014--image-signature-verification-set-the-identity-and-roll-out-in-order) | Trusted upstream image-signing identity and signed-image rollout | Repository admin | Open |
| [R-015](#r-015--repository-security-and-default-branch-protections) | Secret scanning, push protection, and effective default-branch controls | Repository / security admin | Open — settings require owner action |
| [R-016](#r-016--environment-account-isolation-and-deploy-role-scope) | Enforce dev/prod account separation and verify deploy-role scope | AWS account / security owner | Distinct-account guard implemented and locally tested; broad IAM/live evidence open |
| [R-017](#r-017--production-workload-approval-must-bind-to-the-applied-plan) | Bind prod approval to the exact post-platform workload plan | Repository / security admin | Open — current apply gate is insufficient |
---

## R-001 — AWS account and administrative access

**Problem**
`infra/terraform/modules/` declares the full AWS stack (eight modules, 90 resources) and it has
never been applied: there is no AWS account, administrative principal or bootstrap identity.

**Required owner**
AWS account owner / cloud finance approver.

**Required action**
Provision or nominate a separate target account and Region for each of `dev` and `prod`, confirm
the Region (`var.region`; a fixed `us-east-1` aliased provider serves the CloudFront-scoped WAF
regardless), and grant an
engineer a principal able to create IAM, OIDC, S3, DynamoDB, VPC, ECS, RDS, CloudFront, WAFv2,
KMS, Secrets Manager and CloudWatch resources.

**Impact if unresolved**
No workflow that touches AWS (`000`, `100`, `210`, `220`, `330`, `350`, `360`) can run;
only `230` and `300` work.

---

## R-002 — Terraform S3 state backend created out of band

**Problem**
Every root uses an empty `backend "s3" {}`; the bucket and lock table must exist before the first
`terraform init` — Terraform cannot create the backend it is about to use. `000-bootstrap-backend`
will create them once R-001 and R-003 exist; until then they are created by hand.

**Required owner**
AWS account owner (depends on R-001).

**Required action**
Create a separate versioned, SSE-KMS bucket and DynamoDB table with a `LockID` (S) partition key
for each environment, then record `AWS_TARGET_ACCOUNT_ID`, `TFSTATE_BUCKET`, `TFSTATE_LOCK_TABLE`,
`AWS_REGION` and `AWS_REGION_SHORT` in the matching GitHub environment (`dev` or `hub` for prod).
State keys are `<env>/platform.tfstate` and `<env>/workload.tfstate`. The initializer derives
client-, account-, Region- and environment-specific names unless explicit existing names are
provided; it still needs the account and GitHub admin from R-001.

**Impact if unresolved**
No Terraform command past `validate` can run.

---

## R-003 — GitHub OIDC deploy role wired into CI

**Problem**
The identity module provisions the GitHub OIDC provider and a deploy role and exports
`github_deploy_role_arn`. AWS workflows now assume the environment-specific role through
`AWS_DEPLOY_ROLE_ARN`; the role and secret still need to be created and configured before a
workflow can authenticate.

**Required owner**
Repository admin together with the AWS account owner.

**Required action**
Create/import one identity provider and environment-specific role in each target account, scoped
to this client deployment repository's `dev` or `hub` GitHub environment. Store each role ARN as
an environment-scoped `AWS_DEPLOY_ROLE_ARN` secret; long-lived access keys are not an interim
option. The initializer performs the bootstrap and prints the target-specific `terraform init`
and import commands. `hub` still requires manually configured reviewers and branch restrictions
(R-007).

**Impact if unresolved**
No AWS workflow can authenticate to the intended client account.

---

## R-004 — ACM certificates and custom-domain decision

**Problem**
The ALB certificate is required for a working HTTPS-only CloudFront-to-ALB origin. The optional
custom-domain alias requires a validated CloudFront certificate in `us-east-1`. The deployment
workflow fails before planning when the ALB certificate is absent or not in the expected
account/Region; the module's nullable input must not be interpreted as a working deployment.
Someone has to decide the customer-facing domain and who owns its DNS.

**Required owner**
DNS / domain owner.

**Required action**
Issue an ALB certificate in each target account/Region and store its ARN in that environment's
`CNA_ALB_CERTIFICATE_ARN` variable. If using a custom domain, also issue the CloudFront certificate
in `us-east-1` and set `CNA_CUSTOM_DOMAIN_NAME` and `CNA_CLOUDFRONT_CERTIFICATE_ARN` together.

**Impact if unresolved**
`210` refuses to plan without the ALB certificate. The optional custom domain remains unavailable
until its matching certificate and DNS decision are supplied.

---

## R-005 — Amazon Bedrock model access opt-in

**Problem**
`ai_mode: saas` invokes Bedrock through the task role and the application inference profile
Terraform creates. The former module default (`anthropic.claude-3-5-sonnet-20240620-v1:0`) was
stale and did not prove that the selected model was served in a customer's Region, whether it
required a system-defined inference profile, or whether the account had model access. The default
has been removed: `CNA_BEDROCK_MODEL_ID` must now be supplied for each SaaS environment as either
a customer-selected model ID or exact foundation-model/system-defined inference-profile ARN.
Terraform validates the input shape, but only AWS/provider operations and the deployed runtime
probe can establish actual availability and invocation in that account/Region.

**Required owner**
AWS account owner.

**Required action**
Select a model/profile from AWS's current [supported inference profile Region/model reference](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-profiles-support.html)
and verify whether it supports on-demand inference in the deployment Region or is available only
through a system-defined profile. Set `CNA_BEDROCK_MODEL_ID` in the matching GitHub environment,
enable the selected model access for the customer account as required, then use the `210` runtime
probe as live acceptance. AWS documents that an application inference profile can be created from
a supported on-demand foundation model or a system-defined profile; the app invokes the created
application-profile ARN when configured
([invocation guidance](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-profiles-use.html)).
Alternatively deploy with `ai_mode: byo-api`, which does not use Bedrock.

**Impact if unresolved**
Without an explicit valid model selection, Terraform fails closed during a SaaS plan. If the
selected model/profile or account access is not valid, deployment-time resource creation or the
in-environment Converse probe fails; no successful live invocation is claimed here.

**Evidence limits**
AWS official documentation was consulted on 2026-11-04. It requires checking model and profile
support for the selected Region and describes profile-only models; no client account or Region was
queried. Model availability, account access, IAM permissions and successful inference remain
unverified until a customer-authorized deployment and probe.

---

## R-006 — Security review before the first `byo-api` deploy

**Problem**
`ai_mode: byo-api` stores admin-entered Anthropic/OpenAI API keys AES-256-GCM encrypted in the
application database. The core is adding a required non-empty `CNA_BYO_AI_PROVIDERS` allowlist;
AWS must pass the same configured allowlist to both web and api and require
`CNA_AI_ENGINE_DEFAULT` to be a member. The ECS tasks reach provider endpoints through the NAT
gateway; the application allowlist does not enforce network egress and AWS has no provider-specific
FQDN filter today. Security must review credential storage, provider selection, and outbound
network exposure before customer traffic.

**Required owner**
Security.

**Required action**
Complete the core repository's `REVIEW.md` → R-011, review the allowlist/key-handling contract,
decide whether the AWS appliance needs an outbound FQDN control (AWS Network Firewall or a proxy)
before its first `byo-api` deploy, and record the outcome here.

**Impact if unresolved**
`byo-api` cannot be offered to a customer from this appliance.

---

## R-007 — Required reviewers on the `hub` environment

**Problem**
`210-deploy`'s prod `apply` job runs under the `hub` GitHub environment, whose required
reviewers are the human approval gate for production changes. A freshly created repository has no
environments and therefore no gate.

**Required owner**
Repository admin.

**Required action**
Create the `dev`, `prod` and `hub` environments; give `hub` the same required reviewers the core
repository's `hub` environment has; trust subject `environment:hub` of this repository in the OIDC
deploy role (R-003).

**Impact if unresolved**
Prod deploys either fail OIDC or run without human approval.

---

## R-008 — Runtime secrets have no defaults and must be supplied

> Transferred 2026-09-15 from the core repository's `REVIEW.md` → R-006 (core T-507).

**Problem**
Five runtime inputs are declared `sensitive` with **no defaults** and are intentionally absent
from the repository.

**Why it blocks progress**
`terraform apply` on the workload root fails immediately without them. They cannot be committed,
generated by CI, or defaulted safely.

**Required owner**
Security / secret owner (whoever holds the Entra app registration and the Docker Hub
organization).

**Required action**
Supply at apply time, or seed into the chosen secret store:

| Variable | Purpose |
|---|---|
| `db_admin_password` | RDS PostgreSQL master password |
| `nextauth_secret` | NextAuth / Auth.js session secret |
| `entra_client_secret` | Entra ID app-registration client secret |
| `credential_encryption_key` | Application credential-encryption key |
| `dockerhub_username` / `dockerhub_token` | Private image pulls (optional — the module counts off when blank) |

**Impact if unresolved**
No workload apply is possible. Partial supply is worse than none: the database and runtime
modules would apply inconsistently and leave a half-provisioned environment.

**References**
- `infra/terraform/modules/runtime/variables.tf`,
  `infra/terraform/modules/database/variables.tf`
- `.env.example` (the equivalent Azure secret inventory)

**Recommended next step**
Decide where these live for AWS — Secrets Manager seeded out of band, or GitHub environment
secrets passed as `TF_VAR_*`. The Azure side uses Key Vault; the AWS `runtime` module already
provisions Secrets Manager entries, so seeding is the closer mirror.

---

---

## R-009 — Verify the Core repository variables and GitHub App installation

**Problem**
The core repository is now `Work-Cloud_Network_Core`. The AWS `230-image-update` workflow requires
`CORE_OWNER` and `CORE_REPO` to identify the upstream publisher and uses the GitHub App to read its
manifest. This workspace cannot verify the values currently configured in GitHub or whether the
App is installed on the Core repository.

**Why it needs an owner**
Repository variables and GitHub App installations are settings only the repository admin can write.

**Required owner**
Repository admin.

**Required action**
1. Confirm `CORE_OWNER=saulpatino-cbts` and `CORE_REPO=Work-Cloud_Network_Core` in the AWS
   deployment repository; do not infer configured values from this source tree.
2. Confirm the GitHub App has the required access to the Core repository and that Core's image
   publication dispatch targets this deployment repository.
3. Before enabling or relying on automatic image updates, run `230 · Image Update` manually with
   `force: false` and confirm its manifest fetch and signature checks use the intended upstream.
4. Verify the same settings independently in the Azure appliance; this AWS change does not establish
   sibling parity.

**Impact if unresolved**
Image-update behavior is not established: manifest fetch or dispatch can fail, and no claim is made
that the configured source or App access is correct.

**References**
- `.github/workflows/230-image-update.yml` (`vars.CORE_OWNER`, `vars.CORE_REPO`)
- `README.md` → *Client installation and first deployment*

---

## R-010 — Rotate secrets that reached uploaded Terraform plan artifacts

**Problem**
Until 2026-09-23 `210-deploy` uploaded the workload `tfplan-*` file as a run artifact. A saved
Terraform plan stores every variable value in plaintext — `sensitive = true` only redacts CLI
output — so the artifact carried `CNA_POSTGRES_ADMIN_PASSWORD`, `CNA_ENTRA_CLIENT_SECRET`,
`CNA_NEXTAUTH_SECRET` and `CNA_CREDENTIAL_ENCRYPTION_KEY` for anyone with read access to the
repository, for the default 90-day retention. The upload is removed; the artifacts of past runs
are not.

**Required owner**
Security / secret owner.

**Required action**
Delete every `tfplan-*` artifact under **Actions → run → Artifacts** for past `210` runs. No
live AWS environment exists yet, so nothing needs rotating today; if one is deployed before the
artifacts are gone, rotate the four secrets (rotating `CNA_CREDENTIAL_ENCRYPTION_KEY` makes every
stored cloud credential and BYO AI key undecryptable — see the core's `TODO.md` → T-707).

**Impact if unresolved**
Repository readers can recover runtime secret values from old artifacts.

**References**
- v1.0 review finding DEVOPS-002

## R-011 — Deploy role retains broad service permissions

**Problem**
`infra/terraform/modules/identity/main.tf` still grants the deploy role broad service actions such
as `iam:*`, `kms:*`, `ec2:*`, `rds:*`, `cloudfront:*`, and related actions on `Resource = "*"`.
The OIDC trust is now limited to the exact client deployment repository's `dev` or `hub`
environment, and state access is scoped to the environment-specific bucket/key and lock prefix.
Those static scopes do not establish least privilege for the remaining service operations.

**Required owner**
AWS account owner (the policy can only be iterated down against live applies — R-001).

**Required action**
In an isolated non-production account, verify the create/read/tag operations needed by Terraform,
including the transition from the bootstrap inline policy to the managed policy; then narrow
service actions and resource ARNs based on the observed plan/apply and teardown paths. Do not add
wildcard permissions simply to make a run pass. Separately configure required reviewers and
deployment-branch restrictions on `hub` (R-007).

**Impact if unresolved**
An assumed deploy role can still perform broad actions across the account. Live permissions and
the managed-policy transition remain unverified.

**References**
- v1.0 review finding DEVOPS-AWS-001

## R-012 — Object storage for the AWS appliance

**Problem**
The core's web tier (`apps/cna-web/lib/blob.ts`) and `POST /publish` are Azure-Blob-only; the
AWS Terraform injects `CNA_STORAGE_BUCKET`, which nothing reads. Document upload, deliverable
blobs and the client portal cannot work on AWS until the core gains an S3 path (an S3 deployer
exists only in the CLI package).

**Required owner**
Product owner.

**Required action**
Decide whether AWS 1.0 ships findings/dashboards-only (documented limitation) or waits for the
core's S3 path (core `TODO.md` → T-709).

**Impact if unresolved**
Advertised features fail on AWS.

**References**
- v1.0 review findings NET-AWS-005, ARCH-001, ARCH-109

## R-013 — HTTPS origin requires a customer-owned ALB certificate

**Problem**
CloudFront's origin protocol is `https-only`, but the ALB's HTTPS listener has `count = 0` until
the ALB certificate is supplied, and the `:80` listener redirects to a listener that does not
exist. The updated deploy workflow requires and validates the certificate before planning, so a
new environment cannot be deployed without it. Existing environments without the certificate may
still return 502.

**Required owner**
DNS / domain owner (R-004).

**Required action**
Resolve R-004; set the target account/Region's `CNA_ALB_CERTIFICATE_ARN` before running `210`.

**Impact if unresolved**
The AWS appliance cannot serve a single request.

**References**
- v1.0 review finding NET-AWS-002

## R-014 — Configure the trusted image identity and verify deployment targets

**Problem**
`210` and `220` now refuse any image whose cosign signature and SLSA provenance do not verify
against the repository variable `IMAGE_SIGNING_IDENTITY`. The core's image publisher signs its
published digests with its `200-build-images` workflow identity:
`https://github.com/saulpatino-cbts/Work-Cloud_Network_Core/.github/workflows/200-build-images.yml@refs/heads/main`.
Core scan run [41841234214](https://github.com/saulpatino-cbts/Work-Cloud_Network_Core/actions/runs/41841234214)
successfully verified signature and provenance for its scanned image digests. This does not verify
the AWS repository's configured trust variable, images in an AWS release catalog, or customer
deployment. Older rollback targets may predate signing and fail closed.

**Required owner**
Repository admin.

**Required action**
1. A repository administrator must confirm `IMAGE_SIGNING_IDENTITY` is set to the current Core
   workflow subject above in the AWS deployment repository.
2. Use only a signed digest from the intended Core build; run `100-validate-prereqs` and verify the
   target image in the actual deployment workflow before release.
3. Inventory rollback targets and do not select an unsigned or unverified digest; roll forward to
   a signed build when an old target fails verification.
4. If Core changes owner, repository, default branch, or workflow path, update and verify the
   trusted identity before another deployment. Confirm corresponding settings independently in
   Azure; this AWS work does not establish sibling parity.

**Impact if unresolved**
With the variable unset or stale, image verification fails closed and deployment does not proceed.
The successful Core verification in run 41841234214 is upstream evidence only, not client-side
configuration or deployment proof.

**References**
- v1.0 review findings RELEASE-003, IMG-012; core `TODO.md` → T-703

## R-015 — Repository security and default-branch protections

**Problem**
A read-only GitHub settings check found secret scanning and push protection disabled for this
repository. The default branch is `main`; the branch-protection endpoint returned 404 and the
repository ruleset list was empty. Organization rulesets and effective organization permissions
could not be verified because the available API access did not include the required organization
scope. These observations do not establish whether an inherited organization policy applies.

**Required owner**
Repository and security administrators.

**Required action**
Confirm the effective organization and repository policy for `main`, configure the required
branch protection or ruleset controls (including review and status-check requirements appropriate
to the client release process), and enable secret scanning and push protection where entitled.
Then verify the effective settings through an authorized administrative view. Keep the `hub`
environment's required reviewers as a separate production deployment gate (R-007). No settings
were changed as part of this local work.

**Impact if unresolved**
Secrets can be committed without repository push protection, and the effective controls against
direct or unreviewed updates to `main` remain unverified.

**Evidence limits**
The settings observations were returned by a read-only GitHub API query. Organization rulesets
and permissions were not visible to that query; no conclusion is recorded about inherited policy
or who can push directly.

**References**
- Coordinator-provided read-only GitHub settings results for this assignment.

## R-016 — Environment account isolation and deploy-role scope

**Problem**
The deploy-write policy still grants broad service actions on `Resource = "*"`, with some
Project-tag conditions. A dev role and prod role in the same AWS account can therefore cross the
intended environment boundary for services not covered by those tag conditions. As a conservative
local draft decision, this appliance now requires distinct dev/prod accounts and rejects missing,
malformed, or shared account registrations in the initializer and AWS workflow entry paths. This
reduces cross-environment risk but does not make the broad permissions least-privilege within
either account.

**Required owner**
AWS account and security owners.

**Required action**
The AWS account/security owners must provision and verify the separate target accounts, review
the repository-level account registrations, and validate the deploy policy's required
create/read/tag operations and bootstrap-to-runtime transition in an isolated account. Do not
claim the remaining policy is least-privilege or account-backed verified. The coordinator's
distinct-account choice is implemented only as a reviewable local draft; no live account or IAM
change was made.

**Impact if unresolved**
Workflows fail closed until both distinct account registrations exist. Broad IAM permissions
remain capable of affecting resources throughout each individual target account and are
unverified.

**Evidence limits**
The guard and workflow wiring are static/local only. No live account registration, IAM simulation,
plan/apply, or account-level permission test was performed.

## R-017 — Production workload approval must bind to the applied plan

**Problem**
The prod `hub` environment approval currently gates the `apply` job before it applies the platform
and creates the post-platform workload plan. The workload plan and its `terraform apply tfplan`
execute in that same job after approval, so the reviewer did not approve the exact workload plan
that is applied.

**Required owner**
Repository and security administrators.

**Required action**
Redesign the prod workflow so a human approval occurs after the final workload plan is available
and the exact approved plan is the one applied. Do not solve this by uploading an unencrypted
Terraform plan artifact; plans can contain sensitive values and the historical artifact exposure
remains open under R-010. Validate the new approval binding without applying to a live account.

**Impact if unresolved**
The current environment approval is not evidence that the exact post-platform workload changes
were reviewed; production deployment remains blocked.

**Evidence limits**
Workflow ordering was reviewed statically. No live `hub` reviewer configuration or production
run was inspected.
