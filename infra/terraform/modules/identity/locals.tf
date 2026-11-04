locals {
  execution_role_name = "${var.name_prefix}-ecs-execution"
  task_role_name      = "${var.name_prefix}-ecs-task"
  deploy_role_name    = "${var.name_prefix}-github-deploy"

  # Secrets and artifact buckets are named ${name_prefix}/* and
  # ${name_prefix}-artifacts-* respectively. Granting by name-prefix wildcard
  # (rather than importing the concrete ARNs from the runtime/storage modules)
  # keeps identity free of a dependency cycle — see spec §12.1.
  secret_arn_wildcard   = "arn:${data.aws_partition.current.partition}:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.name_prefix}/*"
  artifacts_bucket_arn  = "arn:${data.aws_partition.current.partition}:s3:::${var.name_prefix}-artifacts-*"
  artifacts_objects_arn = "arn:${data.aws_partition.current.partition}:s3:::${var.name_prefix}-artifacts-*/*"
  static_bucket_arn     = "arn:${data.aws_partition.current.partition}:s3:::${var.name_prefix}-static-*"
  static_objects_arn    = "${local.static_bucket_arn}/*"
  logs_bucket_arn       = "arn:${data.aws_partition.current.partition}:s3:::${var.name_prefix}-logs-*"
  logs_objects_arn      = "${local.logs_bucket_arn}/*"

  # OIDC trust subjects for the GitHub deploy role (review AWS-F-03 / R-011).
  # Each environment role trusts only the protected GitHub environment that
  # selects it. Production operations use the separately protected hub gate.
  _repo = "repo:${var.github_owner}/${var.github_repository}"
  deploy_trusted_subjects = var.environment == "prod" ? [
    "${local._repo}:environment:hub",
    ] : [
    "${local._repo}:environment:dev",
  ]

  state_bucket_arn      = "arn:${data.aws_partition.current.partition}:s3:::${var.tfstate_bucket_name}"
  state_objects_arn     = "${local.state_bucket_arn}/${var.environment}/*"
  state_lock_arn        = "arn:${data.aws_partition.current.partition}:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${var.tfstate_lock_table_name}"
  state_lock_key_prefix = "${var.tfstate_bucket_name}/${var.environment}/"
}
