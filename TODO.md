# TODO — engineering work queue

The authoritative engineering backlog for the AWS appliance. Application work belongs
in the core repository's `TODO.md`; this file covers deployment, operations and this repository.

Items requiring external input — an approval, an account, a credential, an access grant — belong
in [`REVIEW.md`](REVIEW.md), not here. Completed work is recorded in [`CHANGELOG.md`](CHANGELOG.md).

**Last reviewed:** 2026-09-22

| Phase | Theme | Items |
|---|---|---|
| [Phase 1](#phase-1--bring-up) | Bring-up | T-101 – T-113 |

---

## Phase 1 — Bring-up

### T-101 — Implement `210-deploy` as a functional AWS release

- **Priority:** High
- **Description:** `210-deploy` is the core's `212` scaffold: it carries the exact input contract
  of the Azure appliance's `210` (`environment`, images, `previous_*_image`, `deploy_mode`,
  `ai_mode`, plus the `workflow_call` trigger `230` uses) but every job fails fast.
- **Dependencies:** `REVIEW.md` R-001 – R-003; R-005 for `saas`.
- **Recommended action:** Replace the guards job by job following the Azure sibling's shape:
  policy gates → platform plan/apply → workload plan/apply (with `-var ai_mode`) → migrator task →
  health verification → release-catalog write (`ai_mode`, `source_repo`, `source_manifest_run_id`
  included, so `230` keeps working). Reuse `scripts/ci/evaluate_deployment_evidence.py`. The
  post-apply identity step is the Entra redirect-URI sync against the CloudFront domain — easy to
  forget because it is not Terraform.
- **Status:** Done 2026-09-23 (`CHANGELOG.md` → Unreleased, Added) — authored and validated, not
  yet run: the first live `210` against the R-001 account is T-108's job. Departures from the plan
  above, each deliberate: the platform root takes no `ai_mode` (AWS has no firewall egress rule to
  open), so `-var ai_mode` goes to the workload only; the platform outputs are passed to the
  workload as `-var` (the AWS roots take them as variables where Azure uses data sources); the
  migrator is a one-off Fargate task registered from the api task definition, because ECS has no
  job resource and the Terraform declares no migrator; and the evidence health metric is ALB
  target-group health, written in the shape `evaluate_deployment_evidence.py` already reads.
  Three things it surfaced are fixed alongside it: the identity module's tag-scoped `ecs:*`
  would have denied every ECS create and describe call (split into create-with-request-tag,
  read and tag-scoped statements, mirrored in the bootstrap script), `entra_tenant_id` had no
  source (new `CNA_ENTRA_TENANT_ID` variable), and `update_apply_evidence.py` wrote Azure-only
  keys (now also a cloud-neutral `edge_host_name`; mirrored to the sibling).

### T-102 — Implement the operational scaffolds

- **Priority:** High
- **Description:** `000`, `100`, `220`, `330`, `350`, `360` fail fast with the Azure
  appliance's inputs. Each header says what the real job does.
- **Dependencies:** T-101's prerequisites.
- **Recommended action:** Implement in band order; keep the inputs byte-identical to the Azure
  sibling; give `350` its daily schedule only once dev has been deployed.
- **Status:** Done 2026-09-23 (`CHANGELOG.md` → Unreleased, Added) — authored and validated, not
  yet run against an account (`REVIEW.md` R-001). Every input is unchanged. Departures from the
  Azure sibling, each deliberate: `330` is a real `terraform destroy` (workload, then platform)
  because AWS has no resource group to delete, and it first forgets the deploy identity in state
  so the destroy cannot delete the role it runs as; `330`'s backend removal refuses while the other
  environment still has state in the shared bucket; `350`'s daily schedule is present but
  commented out until the first green dev `210`, as this item asked; `350`/`360` fail on a plan
  *error* (exit 1) instead of reading it as "no drift" — the Azure versions swallow it, a fix the
  sibling still needs (see the shared-change note in `CHANGELOG.md`); `220`'s `cluster` input keeps
  its wording although the derived name is `cna-<env>-<region_short>-cluster`, because inputs are
  the shared contract. The deploy role gains `dynamodb:CreateTable`/`DescribeTable`/`TagResource`
  (never `DeleteTable`) so `000` can create the lock table under CI.

### T-103 — Add this repository to the shared project board

- **Priority:** Low
- **Description:** `230-image-update`'s `update-available` issues should land on the one project
  board shared with the core and the sibling appliance.
- **Dependencies:** The core repository's `REVIEW.md` → R-012 (token decision).
- **Recommended action:** Add a SHA-pinned `actions/add-to-project` workflow on `issues: opened` and
  `pull_request: opened`, identical in both appliances.
- **Status:** Done (2026-09-23) as far as this repository can go — `380 · Project Board` is
  authored and inert. It runs on `issues: opened|reopened` and
  `pull_request: opened|reopened|ready_for_review`, is skipped while the `PROJECT_BOARD_URL`
  variable is unset, and exits with a notice while the `PROJECT_BOARD_TOKEN` secret is unset;
  once the core's R-012 is decided, setting the two turns it on with no further change. It uses
  `gh project item-add` rather than the recommended `actions/add-to-project`: nothing to
  SHA-pin, and the R-012 token is the only moving part either way. Identical in the Azure appliance (its T-102);
  the core's own copy is its T-505 (its `CLAUDE.md` reserves workflow numbers, so `380` is
  recorded there when the core adopts it).

### T-104 — Consume the `github_deploy_role_arn` output in CI

- **Origin:** core `TODO.md` → T-201, transferred 2026-09-15 (core T-507).
- **Priority:** High
- **Description:** The `identity` module outputs `github_deploy_role_arn` for the role CI assumes
  via `AssumeRoleWithWebIdentity`. Nothing reads that output — CI trigger wiring was explicitly
  out of scope of the AWS code-generation work.
- **Dependencies:** `REVIEW.md` → R-003 (the role must exist and its ARN must be stored as a
  repository secret).
- **Recommended action:** Reference the stored secret from `210-deploy.yml` using
  `aws-actions/configure-aws-credentials` with `id-token: write`, matching the OIDC-only
  credential policy used on the Azure side. No long-lived AWS keys.
- **Status:** Done (2026-09-23) — the CI half. Every workflow that touches AWS (`000`, `100`,
  `210`, `220`, `330`, `350`, `360`) assumes the role with
  `aws-actions/configure-aws-credentials` (SHA-pinned) and `role-to-assume:
  ${{ secrets.AWS_DEPLOY_ROLE_ARN }}` under `permissions: id-token: write`; no workflow carries a
  long-lived key, and `100 · Validate Prerequisites` fails when the secret is missing. The value
  of the secret — the ARN the identity module outputs as `github_deploy_role_arn`, or the one
  `scripts/Initialize-CnaAwsGitHubSecrets.ps1` creates and stores before the first apply — is
  R-003's, a repository-admin step this repository cannot perform.
- **Notes for future engineers:** The deploy role's trust `sub` condition is scoped to
  `repo:<owner>/<repo>:*`. If the workflow is ever moved to a reusable workflow in another
  repository, that condition must be widened deliberately — it is the only thing preventing
  another repository from assuming the role.

### T-105 — Apply the AWS platform root (networking + VPC endpoints)

- **Origin:** core `TODO.md` → T-301, transferred 2026-09-15 (core T-507).
- **Priority:** High
- **Description:** The platform root `infra/terraform/environments/{dev,prod}/platform/`
  creates the VPC, three-tier subnets, NAT, security groups, and the VPC endpoints gated behind
  `var.enable_vpc_endpoints` (default `true`): seven by default, nine with
  `var.enable_ecr_endpoints`. It must be applied before the workload root, which
  consumes its outputs (VPC / subnet / security-group IDs).
- **Dependencies:** `REVIEW.md` → R-001, R-002. Blocks T-106.
- **Recommended action:** `terraform init` with the four `-backend-config` values from R-002, plan,
  review, apply. Confirm all seven endpoints come up before proceeding (nine if the ECR pair is
  enabled).
- **Status:** Blocked on R-001, R-002.
- **Notes for future engineers:** The endpoints and why each exists —

  | Endpoint | Type | Purpose |
  |---|---|---|
  | S3 | Gateway | Free; routes S3 traffic through the VPC |
  | DynamoDB | Gateway | Free; Terraform state locking |
  | Secrets Manager | Interface | ECS task secret injection |
  | CloudWatch Logs | Interface | ECS `awslogs` driver |
  | ECR API | Interface | Private-ECR image pulls — **off by default** (`enable_ecr_endpoints`; T-111) |
  | ECR Docker | Interface | Private-ECR image pulls — **off by default** (`enable_ecr_endpoints`; T-111) |
  | Bedrock Runtime | Interface | AI inference calls |
  | STS | Interface | IAM role credential exchange |
  | X-Ray | Interface | Trace segment submission |

  A dedicated security group (`${name_prefix}-sg-vpce`) allows HTTPS from the app and database
  tiers. The two Gateway endpoints are free; each Interface endpoint carries an hourly charge
  per AZ — that is the deliberate trade for keeping service traffic off the NAT gateway. The ECR
  pair is off because the appliance pulls its images from Docker Hub and the X-Ray daemon from
  ECR Public, neither of which a private ECR endpoint serves; enable it only if the images are
  ever mirrored into a private registry.

### T-106 — Apply the AWS workload root in module order

- **Origin:** core `TODO.md` → T-302, transferred 2026-09-15 (core T-507).
- **Priority:** High
- **Description:** The workload root composes the eight provider modules. They have a required
  order because of IAM and secret dependencies.
- **Dependencies:** T-105, plus `REVIEW.md` → R-004, R-005, R-008.
- **Recommended action:** Apply in this order:
  `identity → storage → database → observability → ai → runtime → compute → security`.
  The workload root reads platform outputs through variables populated from the platform state.
- **Status:** Blocked on T-105.
- **Notes for future engineers:** The platform state and workload state are separate state files
  by design, mirroring the Azure split. Cross-state values move as explicit variables, not remote
  state data sources — keep it that way; it is what makes the two roots independently
  destroyable.

### T-107 — Confirm Bedrock model IDs resolve in the target region

- **Origin:** core `TODO.md` → T-303, transferred 2026-09-15 (core T-507).
- **Priority:** Medium
- **Description:** The `ai` module's `model_ids` variable carries defaults that may not exist in
  every region. A model ID that is unavailable regionally fails at invoke time, not at apply time.
- **Dependencies:** `REVIEW.md` → R-005 (model access opt-in must be done first, otherwise the
  availability check reports a false negative).
- **Recommended action:** After the opt-in, list available foundation models in the deploy region
  and reconcile against the module defaults. Adjust the variable rather than the module.
- **Status:** Blocked on R-005. Since 2026-09-23 `210` proves the outcome on every `saas` release:
  its "Verify the Bedrock path from inside the environment" step makes one Converse call from a
  Fargate task with the api's task role, and the manifest's `bedrock_model_access` /
  `bedrock_task_role_inference` read `passed` or the deployment is not reported healthy.
- **Notes for future engineers:** If the platform keeps calling the external Azure OpenAI endpoint
  from AWS — as the superseded `migrate/` root does today — the `ai` module can be disabled
  entirely and the endpoint stays an environment variable. That is a fallback, not the target
  design.

### T-108 — Verify the AWS parity claims against a live deployment

- **Origin:** core `TODO.md` → T-305, transferred 2026-09-15 (core T-507).
- **Priority:** Medium
- **Description:** The AWS stack is asserted to be at architectural parity with Azure across
  compute, database, edge/WAF, identity/KMS, secrets, storage, AI, tracing, observability, private
  networking, autoscaling, and VPC/networking. Every one of those claims is currently
  code-inspection only — nothing has been applied.
- **Dependencies:** T-106.
- **Recommended action:** After the first successful workload apply, walk the parity matrix
  capability by capability and record the result. Demote any capability that does not hold in
  practice from "complete" to a Phase 5 item.
- **Status:** Blocked on T-106.
- **Notes for future engineers:** The parity matrix as authored —

  | Capability | Azure | AWS |
  |---|---|---|
  | Compute (3 containers) | Container Apps | ECS Fargate + ALB |
  | Database | PostgreSQL Flexible Server | RDS PostgreSQL |
  | Edge/CDN + WAF | Front Door Premium + WAF | CloudFront + WAFv2 |
  | WAF Auth.js exclusions | Field-specific exclusions | Custom rules (query params, cookies, headers) |
  | Identity + KMS | Managed Identity + Key Vault RBAC | IAM roles + KMS CMK + GitHub OIDC |
  | Secrets | Key Vault | Secrets Manager |
  | Storage | Storage Account (blob) | S3 (artifacts + static site) |
  | AI model management | AI Foundry + `cognitive_deployment` | Bedrock inference profile + optional provisioned throughput |
  | Distributed tracing | Application Insights | X-Ray (daemon sidecar + sampling rules) |
  | Observability | Log Analytics + diagnostics + flow logs | CloudWatch log groups + metric filters + alarms + VPC flow logs |
  | Private networking | Private endpoints (storage, KV, AI) | VPC endpoints (9) |
  | Scale-to-zero | Container Apps `min_replicas=0` | Application Auto Scaling (CPU + memory + ALB requests) |
  | VPC/networking | VNet + NSG + subnets | VPC + security groups + 3-tier subnets + NAT |

### T-109 — Optional Route 53 + ACM certificate validation flow

- **Origin:** core `TODO.md` → T-502, transferred 2026-09-15 (core T-507).
- **Priority:** Low
- **Description:** Certificates are inputs (`alb_certificate_arn`, `acm_certificate_arn`, default
  `null`) because minting an unvalidated `aws_acm_certificate` hangs on DNS validation. If the
  zone is hosted in Route 53, an `aws_acm_certificate` +
  `aws_acm_certificate_validation` pair can automate the whole flow.
- **Dependencies:** `REVIEW.md` → R-004 (the domain decision and zone ownership must be settled
  first).
- **Recommended action:** Add the validation flow behind a feature flag defaulting to off, so
  externally hosted DNS keeps the current input-ARN behaviour.
- **Status:** Blocked on R-004.
- **Notes for future engineers:** The CloudFront viewer certificate must be in `us-east-1`
  regardless of deployment region — the repository already declares a `us-east-1` aliased provider
  for the CloudFront-scoped WAF; reuse it.

### T-110 — A scheduled drift check failed daily for five weeks and nothing surfaced it

- **Origin:** core `TODO.md` → T-416, transferred 2026-09-15 (core T-507).
- **Priority:** High
- **Category:** Operational safety
- **Description:** `350-drift-dev.yml` runs on a schedule and failed **every day from 2026-07-21
  to 2026-08-28** with `ResourceGroupNotFound: rg-cna-dev-scus-tfstate`. That failure was the
  first and clearest evidence that the dev environment had been deleted out of band, including its
  Terraform state backend — the single fact that would have changed the plan for the 0.9.0 demo
  work, five weeks before anyone discovered it by trying to deploy (`the core's CNA-0.90-updates.md` §5).
  The workflow did its job perfectly. The gap is that a failing scheduled run notifies nobody:
  GitHub emails the *workflow author* on scheduled-run failure, which for a bot-authored workflow
  reaches no one who acts on it.
- **Dependencies:** None.
- **Recommended action:** Give scheduled-check failures a destination. The cheapest version that
  actually works: on failure, `350-drift-dev` and `360-drift-prod` open (or update) a GitHub
  issue with a fixed title — deduplicating by title so five weeks of failures is one issue that
  gets staler and more visible, not 35 notifications. Assign it to the repository owner. Consider
  the same treatment for `370-registry-cleanup` and any other unattended schedule.
  A second, independent guard is worth its keep given what happened: have the drift workflow
  distinguish "resources drifted" from "the environment does not exist", and treat the second as
  a distinct, louder failure — those mean very different things.
- **Notes for future engineers:** Do not close this by muting the check or by making it tolerate
  a missing backend. The check was right; the delivery was missing.
- **Status:** Done (2026-09-23). `350`/`360` each gain a `report-failure` job that runs when the
  drift job fails and opens a GitHub issue — deduplicated by exact title, so a month of daily
  failures is one issue with one comment per further failure, assigned to the repository owner
  (unassigned if the owner is an organization, rather than not opened) — and the platform
  `terraform init` step classifies the failure: a missing state backend or an empty state is
  reported as **"the environment does not exist"**, its own title and message, distinct from
  "the drift check failed" (init/plan error, expired credential, provider fault). Drift itself
  stays a run warning, never an issue. The plan step also fails on a plan *error* instead of
  reading it as "no drift". `370-registry-cleanup` is the core's workflow and the core's call.
  Mirrored in the Azure appliance in the same change set.

### T-111 — Terraform findings imported from the core's production-readiness review

- **Priority:** Medium
- **Origin:** the core repository's review engine (`cna/review/areas/terraform_aws*.py`), exported 2026-09-15 when the deployment layer left the core (core T-504/T-508). Paths are rebased to this repository's layout.
- **Description:** One entry per recorded finding, in the engine's own words. `INFORMATIONAL` entries are verified-compliant outcomes — kept so the record shows what was checked, not only what was found. Escalations name the `REVIEW.md` blocker that owns them.
- **Recommended action:** Work the MEDIUM/HIGH entries; keep the verified-compliant ones true when the modules change.
- **Status:** Done for every finding that does not need an account (2026-09-23). The six gated
  escalations stay exactly where the engine put them — with `REVIEW.md` R-001 – R-005 and R-008 —
  and the least-privilege tightening of the deploy-write policy to concrete ARNs remains a
  follow-up for the first live account (resource ARNs are unknown until then). Each entry below
  carries its outcome in *italics*.

**Findings**

- **HIGH** `infra/terraform/environments/aws` (`terraform-aws:gated:account`) — The whole AWS stack is authored but never applied: no account is available (REVIEW.md R-001), so terraform plan/apply against a real account and any account-scoped validation cannot run. Escalate — do not attempt a live apply (Requirement 4.6).
- **HIGH** `infra/terraform/environments/aws` (`terraform-aws:gated:account`) — The whole AWS stack is authored but never applied: no account is available (REVIEW.md R-001), so terraform plan/apply against a real account and any account-scoped validation cannot run. Escalate — do not attempt a live apply (Requirement 4.6). *Escalation — owner: this repository's `REVIEW.md` → R-001.*
- **HIGH** `infra/terraform/environments/dev/platform/providers.tf` (`terraform-aws:gated:state-backend`) — Both env roots declare an empty S3 backend (backend "s3" {}) populated via -backend-config at init. No S3 state bucket or DynamoDB lock table exists yet (REVIEW.md R-002), so 'terraform init' with a backend cannot run and validate must use -backend=false. Escalate provisioning of the state backend.
- **HIGH** `infra/terraform/environments/dev/platform/providers.tf` (`terraform-aws:gated:state-backend`) — Both env roots declare an empty S3 backend (backend "s3" {}) populated via -backend-config at init. No S3 state bucket or DynamoDB lock table exists yet (REVIEW.md R-002), so 'terraform init' with a backend cannot run and validate must use -backend=false. Escalate provisioning of the state backend. *Escalation — owner: this repository's `REVIEW.md` → R-002.*
- **HIGH** `infra/terraform/modules/identity/main.tf` (`terraform-aws:gated:oidc-role`) — The identity module creates the GitHub OIDC deploy role and a broad deploy-write policy (ec2:*, rds:*, s3:*, iam:*, kms:* on Resource '*'; ECS is Project-tag scoped). Tightening the wildcard actions to concrete resource ARNs, and wiring CI to the role, both require the live account and the externally provisioned OIDC role (REVIEW.md R-003) — the real resource ARNs are not known without an account. Escalate; record the least-privilege tightening as a follow-up once the account exists.
- **HIGH** `infra/terraform/modules/identity/main.tf` (`terraform-aws:gated:oidc-role`) — The identity module creates the GitHub OIDC deploy role and a broad deploy-write policy (ec2:*, rds:*, s3:*, iam:*, kms:* on Resource '*'; ECS is Project-tag scoped). Tightening the wildcard actions to concrete resource ARNs, and wiring CI to the role, both require the live account and the externally provisioned OIDC role (REVIEW.md R-003) — the real resource ARNs are not known without an account. Escalate; record the least-privilege tightening as a follow-up once the account exists. *Escalation — owner: this repository's `REVIEW.md` → R-003. CI wiring is done (T-101, `AWS_DEPLOY_ROLE_ARN`). What could be fixed without an account was: the policy now also allows `bedrock:*`, `sns:*` and `xray:*` — the stack creates all three and the Terraform-managed policy that replaces the bootstrap script's inline copy after `terraform import` would otherwise have been narrower than the copy, failing the first managed apply. ARN tightening: after the first live apply, read the created ARNs from state and scope each service statement.*
- **MEDIUM** `infra/terraform/modules/ai/main.tf` (`terraform-aws:gated:bedrock`) — The ai module authors the Bedrock invoke policy, inference profile, and (optional) provisioned throughput, but Bedrock foundation-model access must be enabled manually in the Bedrock console per region/account before any invocation succeeds (REVIEW.md R-005) — there is no Terraform resource for the opt-in. Escalate the model-access opt-in.
- **MEDIUM** `infra/terraform/modules/ai/main.tf` (`terraform-aws:gated:bedrock`) — The ai module authors the Bedrock invoke policy, inference profile, and (optional) provisioned throughput, but Bedrock foundation-model access must be enabled manually in the Bedrock console per region/account before any invocation succeeds (REVIEW.md R-005) — there is no Terraform resource for the opt-in. Escalate the model-access opt-in. *Escalation — owner: this repository's `REVIEW.md` → R-005.*
- **MEDIUM** `infra/terraform/modules/compute/main.tf` (`terraform-aws:gated:certificate`) — HTTPS on the ALB (aws_lb_listener.https) and the custom-domain CloudFront alias are gated on an ACM certificate ARN that is created and validated externally (REVIEW.md R-004). Without a cert the HTTPS listener and the API path rule are count=0 and the distribution uses the default CloudFront certificate. Escalate the certificate + custom-domain decision.
- **MEDIUM** `infra/terraform/modules/compute/main.tf` (`terraform-aws:gated:certificate`) — HTTPS on the ALB (aws_lb_listener.https) and the custom-domain CloudFront alias are gated on an ACM certificate ARN that is created and validated externally (REVIEW.md R-004). Without a cert the HTTPS listener and the API path rule are count=0 and the distribution uses the default CloudFront certificate. Escalate the certificate + custom-domain decision. *Escalation — owner: this repository's `REVIEW.md` → R-004.*
- **MEDIUM** `infra/terraform/modules/observability/main.tf` (`terraform-aws:sns-topic-encryption`) — Alarms SNS topic was created without encryption at rest. Set kms_master_key_id to the customer-managed key when supplied and alias/aws/sns otherwise, so alarm notifications are never stored unencrypted. Applied by this task.
- **MEDIUM** `infra/terraform/modules/runtime/main.tf` (`terraform-aws:gated:runtime-secret`) — The runtime module writes Secrets Manager secrets (DATABASE_URL, nextauth, Entra client secret, credential-encryption key, optional Docker Hub creds) whose values are supplied at deploy time by an external owner (REVIEW.md R-008). secret_string is ignored after creation. Escalate provisioning of the real secret values — never invent or commit one.
- **MEDIUM** `infra/terraform/modules/runtime/main.tf` (`terraform-aws:gated:runtime-secret`) — The runtime module writes Secrets Manager secrets (DATABASE_URL, nextauth, Entra client secret, credential-encryption key, optional Docker Hub creds) whose values are supplied at deploy time by an external owner (REVIEW.md R-008). secret_string is ignored after creation. Escalate provisioning of the real secret values — never invent or commit one. *Escalation — owner: this repository's `REVIEW.md` → R-008.*
- **MEDIUM** `infra/terraform/modules/security/main.tf` (`terraform-aws:edge-access-logging`) — CloudFront distribution has no access logging (logging_config) and the WAF web ACL has no logging configuration (aws_wafv2_web_acl_logging_configuration). Add both, pointing at an operator-chosen log destination (an S3 log bucket for CloudFront; a CloudWatch log group or Firehose for WAF), so edge traffic and blocked requests are auditable. Not auto-applied: the log destination is an operator choice, not account-gated. *Done 2026-09-23: the storage module adds an SSE-S3, versioned, public-access-blocked `<prefix>-logs-<hex>` bucket (ACLs enabled, as CloudFront standard logging requires; objects expire after `log_retention_days`); the security module writes CloudFront standard logs to it (`cloudfront/`, cookies excluded) and WAF logs to the us-east-1 log group `aws-waf-logs-<prefix>` with the `cookie` and `authorization` headers redacted. Both gated by the roots' `enable_edge_logging` (default `true`). `330` empties the log bucket before destroy.*
- **MEDIUM** `infra/terraform/modules/storage/main.tf` (`terraform-aws:s3-static-sse-versioning`) — Static-site S3 bucket declared encryption-at-rest only implicitly and had no versioning. Added an explicit aws_s3_bucket_server_side_encryption_configuration (AES256 / SSE-S3 — not SSE-KMS, so CloudFront OAC reads need no kms:Decrypt) and aws_s3_bucket_versioning (Enabled). Applied by this task.
- **LOW** `infra/terraform/modules/compute/locals.tf` (`terraform-aws:xray-sidecar-latest-tag`) — The X-Ray daemon sidecar pins its image to a mutable 'aws-xray-daemon:latest' tag, so a rebuild can silently change the running daemon version. Pin to a specific published tag (or an image digest) for reproducible task definitions. Not auto-applied: the specific pinned version is an operator choice. *Done 2026-09-23: the image is the compute module's `xray_daemon_image` variable, default `public.ecr.aws/xray/aws-xray-daemon:3.7.0` (the newest tag published on ECR Public at the time), with a validation that rejects `:latest` or an untagged reference. Bump the default deliberately.*
- **LOW** `infra/terraform/modules/compute/main.tf` (`terraform-aws:alb-drop-invalid-headers`) — Application Load Balancer did not drop invalid HTTP header fields, so malformed headers were forwarded to the tasks. Set drop_invalid_header_fields = true (request-smuggling / header-injection defense). Applied by this task.
- **LOW** `infra/terraform/modules/database/main.tf` (`terraform-aws:rds-observability-options`) — RDS instance enables neither Performance Insights (performance_insights_enabled) nor enhanced monitoring (monitoring_interval + a monitoring role) nor IAM database authentication (iam_database_authentication_enabled). Consider enabling these for production observability and credential-free auth. Not auto-applied: each carries a cost/behavior trade-off and enhanced monitoring needs a monitoring IAM role. *Done 2026-09-23: the database module takes `performance_insights_enabled` (KMS-encrypted with the platform key, 7-day free retention), `monitoring_interval` (creates the `<prefix>-rds-monitoring` role with `AmazonRDSEnhancedMonitoringRole` when non-zero) and `iam_database_authentication_enabled`. Root defaults: prod enables Performance Insights and 60-second enhanced monitoring, dev enables neither; IAM authentication stays off in both because the application connects with `DATABASE_URL`.*
- **LOW** `infra/terraform/environments/{dev,prod}/platform/main.tf` (`terraform-aws:ecr-endpoints-unused`) — Added 2026-09-23 while working this item. The two ECR interface endpoints (`ecr.api`, `ecr.dkr`) served nothing: the appliance pulls its images from Docker Hub and the X-Ray daemon from ECR Public, neither of which a private ECR endpoint carries, so they were pure hourly cost per AZ. *Done: both are behind a new `enable_ecr_endpoints` variable, default `false`; T-105's endpoint table records the change.*
- **INFORMATIONAL** `infra/terraform/environments/aws` (`terraform-aws:validate-result`) — Verified compliant (Requirements 4.2/4.3): ran 'terraform fmt -check' (clean), 'terraform init -backend=false' (backend init skipped — S3 state backend is gated on R-002), and 'terraform validate' on every AWS root — infra/terraform/environments/dev/platform, infra/terraform/environments/dev/workload, infra/terraform/environments/prod/platform, infra/terraform/environments/prod/workload. Two account-independent validate errors were fixed in-tree by this task: the runtime name_prefix variable description had an unescaped ${name_prefix} interpolation (escaped to $${name_prefix}), and aws_bedrock_inference_profile.chat set the read-only 'type' attribute (removed). After the fixes all four roots validate successfully. No live 'terraform apply' or account 'plan' was run (Requirement 4.6).
- **INFORMATIONAL** `infra/terraform/modules/ai` (`terraform-aws:module-audited:ai`) — Verified compliant: Bedrock invoke policy is scoped to the configured foundation-model / inference-profile ARNs (no bedrock:* wildcard), guardrail + inference profile are optional and tagged.
- **INFORMATIONAL** `infra/terraform/modules/compute` (`terraform-aws:module-audited:compute`) — Verified compliant: ECS Fargate tasks run in private subnets (assign_public_ip=false), have healthchecks, awslogs logging, container-insights on, autoscaling with scale-to-zero, and the ALB redirects HTTP→HTTPS. ALB drop_invalid_header_fields added by 7.1.
- **INFORMATIONAL** `infra/terraform/modules/database` (`terraform-aws:module-audited:database`) — Verified compliant: RDS is not publicly accessible, storage is KMS-encrypted, backups + final-snapshot + deletion-protection are environment-driven, postgresql logs export to CloudWatch, password is sensitive and ignored after create. *Still true; Performance Insights, enhanced monitoring and IAM authentication are now environment-driven too.*
- **INFORMATIONAL** `infra/terraform/modules/identity` (`terraform-aws:module-audited:identity`) — Verified compliant: KMS key rotation on; ECS execution/task roles are name-prefix-scoped to their secrets/buckets/KMS; OIDC subject is pinned to the repo. Broad deploy-write policy is recorded as a gated (R-003) tightening follow-up.
- **INFORMATIONAL** `infra/terraform/modules/observability` (`terraform-aws:module-audited:observability`) — Verified compliant: CloudWatch log groups are KMS-encrypted with retention; X-Ray sampling, metric filters, and baseline alarms are present. Alarms SNS topic encryption added by 7.1.
- **INFORMATIONAL** `infra/terraform/modules/runtime` (`terraform-aws:module-audited:runtime`) — Verified compliant: Secrets Manager secrets are namespaced, recovery-window is environment-driven, and secret_string is ignored after create so external rotation does not drift. Real values are a gated (R-008) deploy-time input.
- **INFORMATIONAL** `infra/terraform/modules/security` (`terraform-aws:module-audited:security`) — Verified compliant: WAFv2 (CLOUDFRONT scope, us-east-1) with AWS managed rule groups + Auth.js field-scoped exclusions; CloudFront OAC + origin protocol https-only + viewer redirect-to-https; static-site bucket policy scoped to the distribution ARN. Access logging recorded as a fixable follow-up. *Access logging done — see the MEDIUM `edge-access-logging` entry.*
- **INFORMATIONAL** `infra/terraform/modules/storage` (`terraform-aws:module-audited:storage`) — Verified compliant: artifacts bucket has SSE-KMS, versioning, public-access-block, and lifecycle tiering. Static-site bucket SSE (AES256) + versioning added by 7.1. *The edge log bucket added 2026-09-23 keeps the same posture (SSE-S3, versioning, public-access-block, lifecycle expiry); it is the one bucket with ACLs enabled, because CloudFront standard logging needs them.*

### T-112 — Write the AWS bootstrap and scanner-account scripts

- **Origin:** repository-split validation, 2026-09-22 (`CHANGELOG.md` → Unreleased, Removed).
- **Priority:** High
- **Description:** The Azure appliance ships two operator scripts this repository has no
  equivalent of: `Initialize-CnaGitHubSecrets.ps1` (creates the deploy identities with their OIDC
  federated credentials and least-privilege roles, the state backend, and writes the GitHub
  secrets and variables) and `New-CnaAssessmentServicePrincipal.ps1` (creates the read-only
  identity the app's "Add Cloud Connection" form asks for). Neither was ever written for AWS —
  the original repository only had them for Azure — so `REVIEW.md` R-001 – R-003 are done by hand
  today, and a customer has no scripted way to create the `ReadOnlyAccess` + `SecurityAudit` +
  `AWSBillingReadOnlyAccess` scanner role with an external ID in every in-scope account.
- **Dependencies:** `REVIEW.md` R-001 (an account to run against).
- **Recommended action:** Two scripts under `scripts/`, same names with `Aws` in place of the Azure
  wording, idempotent like the Azure ones: (1) bootstrap — OIDC provider, `github_deploy` role via
  the `identity` module's trust policy, S3 state bucket + DynamoDB lock table, then the
  `AWS_DEPLOY_ROLE_ARN`, `TFSTATE_*` and `AWS_REGION*` GitHub secrets and variables; (2) scanner —
  a CloudFormation StackSet or per-account role with the three managed policies and an external
  ID, emitting the role ARN and account CSV the form imports. Never accept or print a credential
  value.
- **Status:** Done 2026-09-23 (`CHANGELOG.md` → Unreleased, Added): `scripts/Initialize-CnaAwsGitHubSecrets.ps1`
  and `scripts/New-CnaAwsAssessmentRole.ps1`. Two deliberate departures from the plan above: the
  AWS form takes a role ARN, external ID and access key rather than an account list, so the scanner
  script emits those (discovery lists the organization's accounts itself) and no CSV; and the
  scanner's own access key is the one credential the scanner script does print — once, to the
  console only, because the form has nothing else to authenticate with. Both scripts are
  untested against a live account until `REVIEW.md` R-001 lands (T-108).

### T-113 — Inject the MCP and draw.io endpoints the Azure workload roots already pass

- **Origin:** repository-split validation, 2026-09-22 (`CHANGELOG.md` → Unreleased, Removed).
- **Priority:** Medium
- **Description:** The Azure workload roots pass `CNA_AZURE_MCP_ENDPOINT`,
  `CNA_AZURE_MCP_TRANSPORT`, `CNA_AWS_MCP_ENDPOINT`, `CNA_AWS_MCP_TRANSPORT` and
  `CNA_DRAWIO_MCP_URL` to the api and worker containers (from `azure_mcp_*`, `aws_mcp_*` and
  `drawio_mcp_url` variables). Both AWS workload roots omit all five, so on AWS the recommendation
  engine's direct MCP clients and draw.io rendering fall back to their code defaults (offline
  library, `localhost`). This predates the split — the gap is in the original repository's
  `infra/terraform/environments/aws` too — but it is a parity gap between the two appliances.
- **Dependencies:** none for the Terraform; T-108 to verify against a live deployment.
- **Recommended action:** Add the five variables to `environments/{dev,prod}/workload/variables.tf`
  with the same names, defaults and descriptions as the Azure sibling, pass them in the same
  `environment` map the Azure roots do (the web tier's — the Azure roots do not pass them to api
  or worker either), and surface them in `210-deploy` exactly as Azure's `210` does. Cloud-specific
  file bodies only; no shared-file change.
- **Status:** Done 2026-09-23 for the Terraform (`CHANGELOG.md` → Unreleased, Added). The
  `210-deploy` half waits on T-101: the workflow is still a scaffold with no `terraform plan`
  step to add the `-var` lines to — T-101 must pass `azure_mcp_endpoint`, `azure_mcp_transport`,
  `aws_mcp_endpoint`, `aws_mcp_transport` and `drawio_mcp_url` from the `CNA_*` repository
  variables the way Azure's `210` does.

### T-114 — Mirror the cosign attestation parsing fix in the Azure appliance

- **Origin:** PR #16 review, 2026-10-03.
- **Priority:** High
- **Description:** The shared `scripts/ci/verify_image_signature.sh` now reads the in-toto
  statements that cosign prints directly as JSON. The Azure sibling still needs the same fix so
  both appliances can verify valid provenance attestations.
- **Dependencies:** None.
- **Recommended action:** In
  `saulpatinojr/Work-Cloud_Network_Azure_Appliance/scripts/ci/verify_image_signature.sh`, replace
  the DSSE `.payload` extraction and base64 decoding with parsing of cosign's direct JSON
  statements, and require their subject digest to match the deployed immutable reference.
- **Status:** Open — this repository cannot update the sibling appliance in this change.
