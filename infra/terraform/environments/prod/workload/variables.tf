variable "project_name" {
  description = "Project name used in resource naming (mirrors Azure's var.project_name)"
  type        = string
  default     = "cna"
}

variable "environment" {
  description = "Deployment environment (dev or prod)"
  type        = string
  default     = "prod"
}

variable "region" {
  description = "AWS region for the CNA Platform deployment, e.g. us-east-1 or eu-west-1. You must set this; there is no default so no region is ever assumed for you. See the AWS Regions list: https://docs.aws.amazon.com/global-infrastructure/latest/regions/aws-regions.html"
  type        = string

  validation {
    condition     = length(trimspace(var.region)) > 0
    error_message = "Set region to your chosen AWS region (for example us-east-1). It has no default on purpose."
  }
}

variable "region_short" {
  description = "Short code for your region, used in resource naming so names stay readable and unique (mirrors Azure's var.region_short), e.g. use1 for us-east-1. You choose it; there is no default."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.region_short))
    error_message = "Set region_short to a short lowercase code (2-8 letters/digits), for example use1 for us-east-1."
  }
}

# ─── GitHub ───────────────────────────────────────────────────────────────────
variable "github_owner" {
  description = "GitHub organization/owner for the github provider and the OIDC deploy role."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository name (without owner) for the OIDC deploy role trust policy."
  type        = string
}

variable "github_token" {
  description = "GitHub token for the github provider."
  type        = string
  sensitive   = true
  default     = ""
}

# ─── Platform networking (consumed from the platform state) ───────────────────
variable "vpc_id" {
  description = "VPC ID from the platform environment."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs from the platform environment (for the ALB)."
  type        = list(string)
  nullable    = false
}

variable "app_subnet_ids" {
  description = "Application subnet IDs from the platform environment (for the ECS tasks)."
  type        = list(string)
  nullable    = false
}

variable "database_subnet_ids" {
  description = "Database subnet IDs from the platform environment (for the RDS subnet group)."
  type        = list(string)
  nullable    = false
}

variable "alb_security_group_id" {
  description = "ALB security group ID from the platform environment."
  type        = string
}

variable "app_security_group_id" {
  description = "Application security group ID from the platform environment."
  type        = string
}

variable "database_security_group_id" {
  description = "Database security group ID from the platform environment."
  type        = string
}

# ─── Container images ─────────────────────────────────────────────────────────
# Pinned references validated by the deploy workflow (230 · Image Update or the
# core's latest-build.json) and passed with -var. No default: a placeholder
# would plan cleanly and fail at pull time.
variable "api_image" {
  description = "Container image for CNA API, pinned: docker.io/<namespace>/cna:api-sha-<7>@sha256:<digest>"
  type        = string
}

variable "worker_image" {
  description = "Container image for CNA worker, pinned: docker.io/<namespace>/cna:worker-sha-<7>@sha256:<digest>"
  type        = string
}

variable "web_image" {
  description = "Container image for CNA Web, pinned: docker.io/<namespace>/cna:web-sha-<7>@sha256:<digest>"
  type        = string
}

# ─── Scaling / FinOps ─────────────────────────────────────────────────────────
variable "enable_scale_to_zero" {
  description = "Collapse all ECS service desired counts to 0 when idle. Dev cost saving; disabled in prod."
  type        = bool
  default     = false
}

# ─── Database ─────────────────────────────────────────────────────────────────
variable "db_admin_username" {
  description = "RDS master username."
  type        = string
  default     = "cnaadmin"
}

variable "db_admin_password" {
  description = "RDS master password."
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.small"
}

variable "db_allocated_storage_gb" {
  description = "RDS initial allocated storage in GB."
  type        = number
  default     = 20
}

variable "postgres_major_version" {
  description = "PostgreSQL major version (e.g. \"16\")."
  type        = string
  default     = "16"
}

variable "db_multi_az" {
  description = "Enable Multi-AZ for RDS. Disabled in dev, enabled in prod."
  type        = bool
  default     = true
}

variable "db_backup_retention_days" {
  description = "RDS automated backup retention in days."
  type        = number
  default     = 7
}

variable "db_deletion_protection" {
  description = "Prevent accidental RDS deletion. Disabled in dev, enabled in prod."
  type        = bool
  default     = true
}

variable "db_skip_final_snapshot" {
  description = "Skip the final RDS snapshot on destroy. True in dev, false in prod."
  type        = bool
  default     = false
}

# ─── Secrets (Secrets Manager) ────────────────────────────────────────────────
variable "db_performance_insights_enabled" {
  description = "Enable RDS Performance Insights on the PostgreSQL instance (encrypted with the platform KMS key, 7-day free retention)."
  type        = bool
  default     = true
}

variable "db_monitoring_interval" {
  description = "RDS enhanced-monitoring interval in seconds; 0 disables it (and its monitoring role)."
  type        = number
  default     = 60
}

variable "db_iam_authentication_enabled" {
  description = "Allow IAM-token authentication to PostgreSQL alongside the password. Off: the application uses DATABASE_URL."
  type        = bool
  default     = false
}

variable "enable_edge_logging" {
  description = "CloudFront standard access logs to the edge log bucket and WAF web-ACL logs to CloudWatch (us-east-1). Retention follows log_retention_days."
  type        = bool
  default     = true
}

variable "nextauth_secret" {
  description = "Auth.js JWT signing secret."
  type        = string
  sensitive   = true
}

variable "entra_client_secret" {
  description = "Entra ID OAuth client secret."
  type        = string
  sensitive   = true
}

variable "credential_encryption_key" {
  description = "Base64-encoded AES-256 key for encrypting stored credentials."
  type        = string
  sensitive   = true
}

variable "dockerhub_username" {
  description = "Docker Hub username for private image pulls. Empty disables the Docker Hub secret."
  type        = string
  default     = ""
}

variable "dockerhub_token" {
  description = "Docker Hub access token."
  type        = string
  sensitive   = true
  default     = ""
}

# ─── Application configuration (plain env) ────────────────────────────────────
variable "nextauth_url" {
  description = "Canonical URL for Auth.js callbacks (typically the CloudFront domain)."
  type        = string
  default     = ""
}

variable "entra_tenant_id" {
  description = "Entra ID tenant ID for SSO."
  type        = string
  default     = ""
}

variable "entra_client_id" {
  description = "Entra ID application client ID."
  type        = string
  default     = ""
}

# ─── AI Engine ────────────────────────────────────────────────────────────────
variable "ai_mode" {
  description = "AI provisioning mode, selected in the deploy workflow's Run-workflow dialog. saas = provision the Bedrock invoke policy and inference profile and inject CNA_BEDROCK_*; byo-api = provision NO cloud AI resources — admins enter Anthropic/OpenAI API keys on /admin/ai-engine (stored AES-256-GCM encrypted in Postgres). Flipping a live environment between modes is destructive for the AI resources."
  type        = string
  default     = "saas"
  nullable    = false

  validation {
    condition     = contains(["saas", "byo-api"], var.ai_mode)
    error_message = "ai_mode must be \"saas\" or \"byo-api\"."
  }
}

variable "ai_engine_default" {
  description = "Default global GenAI engine when no ai.activeEngine database setting exists. Must match ai_mode: saas on AWS => bedrock; byo-api => anthropic or openai (only consulted as the tie-break when both BYO keys are present)."
  type        = string
  default     = "bedrock"

  validation {
    condition     = contains(["azure-openai", "bedrock", "anthropic", "openai"], var.ai_engine_default)
    error_message = "ai_engine_default must be one of azure-openai, bedrock, anthropic, openai."
  }

  validation {
    condition = (
      var.ai_mode == "saas"
      ? var.ai_engine_default == "bedrock"
      : contains(["anthropic", "openai"], var.ai_engine_default)
    )
    error_message = "ai_engine_default is incompatible with ai_mode: saas on AWS requires bedrock; byo-api requires anthropic or openai."
  }
}

# ─── MCP endpoints (surfaced in cna-web) ──────────────────────────────────────
# Same five variables as the Azure sibling's workload roots; all optional, so an
# unset value leaves the app on its code defaults (offline library, localhost).
variable "azure_mcp_endpoint" {
  description = "Azure MCP server endpoint surfaced in cna-web."
  type        = string
  default     = ""
}

variable "azure_mcp_transport" {
  description = "Azure MCP server transport."
  type        = string
  default     = "streamable-http"
}

variable "aws_mcp_endpoint" {
  description = "AWS MCP server endpoint surfaced in cna-web."
  type        = string
  default     = ""
}

variable "aws_mcp_transport" {
  description = "AWS MCP server transport."
  type        = string
  default     = "streamable-http"
}

variable "drawio_mcp_url" {
  description = "draw.io MCP endpoint surfaced in cna-web."
  type        = string
  default     = ""
}

# ─── TLS / edge ───────────────────────────────────────────────────────────────
variable "alb_certificate_arn" {
  description = "ACM certificate ARN (in var.region) for the ALB HTTPS listener. Null skips the HTTPS listener."
  type        = string
  default     = null
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN in us-east-1 for the CloudFront custom domain. Null uses the default CloudFront certificate."
  type        = string
  default     = null
}

variable "custom_domain_name" {
  description = "Custom domain (CNAME alias) for CloudFront. Empty uses the default CloudFront domain."
  type        = string
  default     = ""
}

variable "waf_override_action" {
  description = "WAF managed rule override action: \"none\" enforces, \"count\" only counts."
  type        = string
  default     = "none"
}

# ─── Identity / KMS ───────────────────────────────────────────────────────────
variable "kms_deletion_window_days" {
  description = "KMS key deletion window in days (7-30)."
  type        = number
  default     = 30
}

# ─── Observability ────────────────────────────────────────────────────────────
variable "log_retention_days" {
  description = "Retention, in days, for the ECS service log groups."
  type        = number
  default     = 30
}

# ─── X-Ray / Observability ────────────────────────────────────────────────────
variable "enable_xray" {
  description = "Enable X-Ray distributed tracing. Mirrors Azure Application Insights."
  type        = bool
  default     = true
}

# ─── Bedrock AI ───────────────────────────────────────────────────────────────
variable "enable_bedrock_inference_profile" {
  description = "Create a Bedrock inference profile (stable model endpoint). Mirrors Azure cognitive_deployment."
  type        = bool
  default     = true
}
