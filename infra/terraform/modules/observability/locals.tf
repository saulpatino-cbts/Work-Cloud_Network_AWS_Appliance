locals {
  api_log_group_name = "/ecs/${var.name_prefix}/api"
  web_log_group_name = "/ecs/${var.name_prefix}/web"

  # ECS cluster/service and RDS instance names are deterministic from
  # name_prefix (see compute + database modules), so the alarms can reference
  # them by dimension even though observability applies BEFORE compute — the
  # alarms simply report INSUFFICIENT_DATA until those resources exist.
  cluster_name   = "${var.name_prefix}-cluster"
  db_instance_id = "${var.name_prefix}-psql"

  services = {
    api = "${var.name_prefix}-api"
    web = "${var.name_prefix}-web"
  }

  alarm_services = var.enable_alarms ? local.services : {}

  alarms_topic_arn = var.sns_topic_arn != null ? var.sns_topic_arn : one(aws_sns_topic.alarms[*].arn)
  alarm_actions    = local.alarms_topic_arn != null ? [local.alarms_topic_arn] : []

  # Custom metric namespace for application-level metric filters (mirrors
  # Azure Application Insights custom metrics).
  custom_metric_namespace = "CNA/${var.name_prefix}"

  # X-Ray daemon log group name (consumed by compute module for sidecar config).
  xray_log_group_name = "/ecs/${var.name_prefix}/xray-daemon"
}
