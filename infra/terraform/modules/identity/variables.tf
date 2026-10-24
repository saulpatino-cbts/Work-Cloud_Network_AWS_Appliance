variable "name_prefix" {
  description = "Normalized name prefix for identity resources (e.g. cna-dev-use1)"
  type        = string
}

variable "tags" {
  description = "Tags applied to identity resources"
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "environment" {
  description = "Deployment environment (dev or prod)"
  type        = string
}

variable "project_name" {
  description = "Project name used for tag-scoped deploy permissions (matches the Project default tag)"
  type        = string
}

variable "kms_deletion_window_days" {
  description = "Waiting period, in days, before the customer-managed KMS key is deleted after destroy (7-30)."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30
    error_message = "kms_deletion_window_days must be between 7 and 30."
  }
}

variable "github_owner" {
  description = "GitHub organization or user that owns the repository allowed to assume the deploy role via OIDC."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository name (without owner) allowed to assume the deploy role via OIDC."
  type        = string
}

variable "task_bedrock_policy_json" {
  description = "Optional IAM policy JSON (produced by the ai module) granting the ECS task role Bedrock InvokeModel access. When null, no Bedrock policy is attached to the task role."
  type        = string
  default     = null
}

variable "enable_xray" {
  description = "Attach X-Ray write permissions to the ECS task role. Mirrors Azure Application Insights auto-instrumentation."
  type        = bool
  default     = true
}

# ─── OIDC deploy-role trust scoping (review AWS-F-03 / REVIEW.md R-011) ────────
variable "default_branch" {
  description = "Default branch whose GitHub Actions runs may assume the deploy role (e.g. main). Used to scope the OIDC trust subject away from any-branch."
  type        = string
  default     = "main"
}

variable "deploy_trusted_subjects" {
  description = "Override the OIDC trust subjects for the deploy role. Empty (default) scopes trust to the default branch plus the dev/prod/hub environments. Set explicitly (e.g. for a reusable workflow in another repo) — never widen to a blanket 'repo:owner/repo:*'."
  type        = list(string)
  default     = []
  nullable    = false
}
