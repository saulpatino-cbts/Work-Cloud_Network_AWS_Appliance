# =============================================================================
# Workload — wires the eight AWS provider modules. Platform networking outputs
# are consumed as var.* (fed from the platform state). Terraform resolves the
# actual apply order from the dependency graph; the logical order mirrors the
# Azure workload: identity/ai -> storage/database/observability -> runtime ->
# compute -> security.
# =============================================================================

# ─── AI (Bedrock policy document + inference profile; consumed by identity) ───
# Only in saas mode. byo-api provisions no cloud AI resources at all; the app
# talks to Anthropic/OpenAI with admin-entered keys instead.
module "ai" {
  count  = local.ai_saas ? 1 : 0
  source = "../../../modules/ai"

  name_prefix              = local.name_prefix
  tags                     = local.tags
  environment              = var.environment
  model_ids                = var.ai_mode == "saas" ? [var.bedrock_model_id] : []
  enable_inference_profile = var.enable_bedrock_inference_profile
}

# No AWS state exists yet, so this is a no-op today; it is correct the moment
# a saas environment applied before count was added gets upgraded.
moved {
  from = module.ai
  to   = module.ai[0]
}

# ─── Identity (KMS, ECS roles, GitHub OIDC) ───────────────────────────────────
module "identity" {
  source = "../../../modules/identity"

  name_prefix              = local.name_prefix
  tags                     = local.tags
  environment              = var.environment
  project_name             = var.project_name
  kms_deletion_window_days = var.kms_deletion_window_days
  github_owner             = var.github_owner
  github_repository        = var.github_repository
  tfstate_bucket_name      = var.tfstate_bucket_name
  tfstate_lock_table_name  = var.tfstate_lock_table_name
  # null in byo-api (module.ai has count 0) — identity already gates the policy
  # attachment on null.
  task_bedrock_policy_json = one(module.ai[*].task_bedrock_policy_json)
  enable_xray              = var.enable_xray
}

# ─── Storage (S3 artifacts + static-site) ─────────────────────────────────────
module "storage" {
  source = "../../../modules/storage"

  name_prefix        = local.name_prefix
  tags               = local.tags
  kms_key_arn        = module.identity.kms_key_arn
  log_retention_days = var.log_retention_days
}

# ─── Database (RDS PostgreSQL) ────────────────────────────────────────────────
module "database" {
  source = "../../../modules/database"

  name_prefix            = local.name_prefix
  tags                   = local.tags
  subnet_ids             = var.database_subnet_ids
  security_group_ids     = [var.database_security_group_id]
  admin_username         = var.db_admin_username
  admin_password         = var.db_admin_password
  instance_class         = var.db_instance_class
  allocated_storage_gb   = var.db_allocated_storage_gb
  postgres_major_version = var.postgres_major_version
  multi_az               = var.db_multi_az
  backup_retention_days  = var.db_backup_retention_days
  deletion_protection    = var.db_deletion_protection
  skip_final_snapshot    = var.db_skip_final_snapshot
  kms_key_id             = module.identity.kms_key_arn

  performance_insights_enabled        = var.db_performance_insights_enabled
  monitoring_interval                 = var.db_monitoring_interval
  iam_database_authentication_enabled = var.db_iam_authentication_enabled
}

# ─── Observability (CloudWatch log groups + alarms) ───────────────────────────
module "observability" {
  source = "../../../modules/observability"

  name_prefix        = local.name_prefix
  tags               = local.tags
  log_retention_days = var.log_retention_days
  kms_key_arn        = module.identity.kms_key_arn
}

# ─── Runtime (Secrets Manager) ────────────────────────────────────────────────
module "runtime" {
  source = "../../../modules/runtime"

  name_prefix               = local.name_prefix
  tags                      = local.tags
  environment               = var.environment
  db_endpoint               = module.database.endpoint
  db_username               = var.db_admin_username
  db_password               = var.db_admin_password
  db_name                   = module.database.db_name
  nextauth_secret           = var.nextauth_secret
  entra_client_secret       = var.entra_client_secret
  credential_encryption_key = var.credential_encryption_key
  dockerhub_username        = var.dockerhub_username
  dockerhub_token           = var.dockerhub_token
}

# ─── Compute (ECS Fargate + ALB + Autoscaling) ────────────────────────────────
module "compute" {
  source = "../../../modules/compute"

  name_prefix = local.name_prefix
  tags        = local.tags
  aws_region  = var.region

  vpc_id                = var.vpc_id
  public_subnet_ids     = var.public_subnet_ids
  app_subnet_ids        = var.app_subnet_ids
  alb_security_group_id = var.alb_security_group_id
  app_security_group_id = var.app_security_group_id

  task_execution_role_arn = module.identity.task_execution_role_arn
  task_role_arn           = module.identity.task_role_arn

  alb_certificate_arn  = var.alb_certificate_arn
  enable_scale_to_zero = var.enable_scale_to_zero
  enable_autoscaling   = true

  # X-Ray tracing (mirrors Azure Application Insights)
  enable_xray         = var.enable_xray
  xray_log_group_name = module.observability.xray_log_group_name != null ? module.observability.xray_log_group_name : ""

  api_image    = var.api_image
  worker_image = var.worker_image
  web_image    = var.web_image

  api_log_group_name    = module.observability.api_log_group_name
  worker_log_group_name = module.observability.worker_log_group_name
  web_log_group_name    = module.observability.web_log_group_name

  dockerhub_secret_arn = module.runtime.dockerhub_secret_arn

  # AI env (local.bedrock_env_vars, saas only) and the mode contract
  # (local.ai_mode_env_vars) are merged in from locals.tf so the two modes
  # differ only by those keys. Mirrors the Azure workload.
  api_environment = merge(
    {
      CNA_STORAGE_BUCKET = module.storage.artifacts_bucket_id
      AWS_REGION         = var.region
    },
    local.bedrock_env_vars,
    local.ai_mode_env_vars,
    local.byo_ai_env_vars,
  )

  worker_environment = merge(
    {
      CNA_STORAGE_BUCKET = module.storage.artifacts_bucket_id
      AWS_REGION         = var.region
    },
    local.bedrock_env_vars,
    local.ai_mode_env_vars,
  )

  # CNA_API_INTERNAL_URL (http://api:<port> over Service Connect) is added by
  # the compute module itself, next to the Service Connect wiring it names.
  web_environment = merge(
    {
      NEXTAUTH_URL            = var.nextauth_url
      AUTH_TRUST_HOST         = "true"
      AZURE_AD_TENANT_ID      = var.entra_tenant_id
      AZURE_AD_CLIENT_ID      = var.entra_client_id
      CNA_STORAGE_BUCKET      = module.storage.artifacts_bucket_id
      AWS_REGION              = var.region
      CNA_AZURE_MCP_ENDPOINT  = var.azure_mcp_endpoint
      CNA_AZURE_MCP_TRANSPORT = var.azure_mcp_transport
      CNA_AWS_MCP_ENDPOINT    = var.aws_mcp_endpoint
      CNA_AWS_MCP_TRANSPORT   = var.aws_mcp_transport
      CNA_DRAWIO_MCP_URL      = var.drawio_mcp_url
    },
    local.bedrock_env_vars,
    local.ai_mode_env_vars,
    local.byo_ai_env_vars,
    local.image_update_env_vars,
  )

  # CNA_API_TOKEN is the bearer token the api requires on every request and
  # the web tier presents (core contract); both read the same generated secret.
  # In byo-api mode cna-api decrypts the admin-entered AI keys from AppSetting,
  # so it needs the same encryption key the web tier uses.
  api_secrets = merge(
    {
      DATABASE_URL  = module.runtime.database_url_secret_arn
      CNA_API_TOKEN = module.runtime.api_token_secret_arn
    },
    local.ai_saas ? {} : { CREDENTIAL_ENCRYPTION_KEY = module.runtime.credential_encryption_key_secret_arn },
  )

  worker_secrets = {
    DATABASE_URL = module.runtime.database_url_secret_arn
  }

  web_secrets = merge(
    {
      DATABASE_URL              = module.runtime.database_url_secret_arn
      AUTH_SECRET               = module.runtime.nextauth_secret_arn
      AZURE_AD_CLIENT_SECRET    = module.runtime.entra_client_secret_arn
      CREDENTIAL_ENCRYPTION_KEY = module.runtime.credential_encryption_key_secret_arn
      CNA_API_TOKEN             = module.runtime.api_token_secret_arn
    },
    # The password key of the same Secrets Manager secret ECS pulls with
    # (repositoryCredentials); the execution role already reads it.
    var.dockerhub_username != "" ? { CNA_IMAGE_REGISTRY_TOKEN = "${module.runtime.dockerhub_secret_arn}:password::" } : {},
  )
}

# ─── Security (edge: WAF us-east-1 + CloudFront + OAC) ────────────────────────
module "security" {
  source = "../../../modules/security"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name_prefix            = local.name_prefix
  tags                   = local.tags
  alb_dns_name           = module.compute.alb_dns_name
  waf_override_action    = var.waf_override_action
  custom_domain_name     = var.custom_domain_name
  acm_certificate_arn    = var.acm_certificate_arn
  static_site_bucket_id  = module.storage.static_site_bucket_id
  static_site_bucket_arn = module.storage.static_site_bucket_arn

  enable_edge_logging    = var.enable_edge_logging
  log_bucket_domain_name = module.storage.logs_bucket_domain_name
  log_retention_days     = var.log_retention_days
}
