# =============================================================================
# Observability — ECS log groups, X-Ray tracing, Contributor Insights, metric
# filters, and baseline alarms. Mirrors the Azure observability module (App
# Insights + diagnostic settings + VNet flow logs). Created BEFORE the compute
# module, which consumes the two log-group names and the X-Ray daemon config.
# =============================================================================

# ─── ECS service log groups ───────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "api" {
  name              = local.api_log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, { Name = "${var.name_prefix}-api-logs" })
}

resource "aws_cloudwatch_log_group" "web" {
  name              = local.web_log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, { Name = "${var.name_prefix}-web-logs" })
}

# ─── X-Ray tracing log group ──────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "xray" {
  count             = var.enable_xray ? 1 : 0
  name              = "/ecs/${var.name_prefix}/xray-daemon"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, { Name = "${var.name_prefix}-xray-logs" })
}

# ─── X-Ray sampling rule ──────────────────────────────────────────────────────
# Custom sampling rule scoped to this platform's services (reduces noise/cost).
resource "aws_xray_sampling_rule" "platform" {
  count = var.enable_xray ? 1 : 0

  rule_name      = "${var.name_prefix}-default"
  priority       = 1000
  reservoir_size = 1
  fixed_rate     = var.xray_sampling_rate
  host           = "*"
  http_method    = "*"
  url_path       = "*"
  service_name   = "${var.name_prefix}-*"
  service_type   = "*"
  resource_arn   = "*"
  version        = 1

  tags = merge(var.tags, { Name = "${var.name_prefix}-xray-sampling" })
}

# ─── CloudWatch Contributor Insights rules ────────────────────────────────────
# Mirrors Azure's Application Insights "top contributors" analytics. Identifies
# top requesters, top error paths, and top slow endpoints from ECS structured logs.
resource "aws_cloudwatch_log_group" "contributor_insights" {
  count             = var.enable_contributor_insights ? 1 : 0
  name              = "/ecs/${var.name_prefix}/contributor-insights"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, { Name = "${var.name_prefix}-contributor-insights" })
}

# ─── Metric filters (application-level signals from structured logs) ──────────
# These extract application metrics from the ECS logs, mirroring Azure App
# Insights' automatic request/dependency/exception telemetry.

resource "aws_cloudwatch_log_metric_filter" "api_errors" {
  name           = "${var.name_prefix}-api-errors"
  pattern        = "{ $.level = \"ERROR\" }"
  log_group_name = aws_cloudwatch_log_group.api.name

  metric_transformation {
    name          = "ApiErrors"
    namespace     = local.custom_metric_namespace
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "api_latency" {
  name           = "${var.name_prefix}-api-latency"
  pattern        = "{ $.duration_ms = * }"
  log_group_name = aws_cloudwatch_log_group.api.name

  metric_transformation {
    name          = "ApiLatencyMs"
    namespace     = local.custom_metric_namespace
    value         = "$.duration_ms"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "web_errors" {
  name           = "${var.name_prefix}-web-errors"
  pattern        = "{ $.level = \"ERROR\" }"
  log_group_name = aws_cloudwatch_log_group.web.name

  metric_transformation {
    name          = "WebErrors"
    namespace     = local.custom_metric_namespace
    value         = "1"
    default_value = "0"
  }
}

# ─── Application error rate alarm ─────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "api_error_rate" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${var.name_prefix}-api-error-rate-high"
  namespace           = local.custom_metric_namespace
  metric_name         = "ApiErrors"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.alarm_thresholds.api_error_count
  evaluation_periods  = 2
  period              = 300
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = merge(var.tags, { Name = "${var.name_prefix}-api-error-rate-high" })
}

# ─── ALB latency alarm (p99) ──────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "alb_latency_p99" {
  count = var.enable_alarms && var.alb_arn_suffix != null ? 1 : 0

  alarm_name          = "${var.name_prefix}-alb-latency-p99-high"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.alarm_thresholds.alb_latency_p99_seconds
  evaluation_periods  = 3
  period              = 300
  extended_statistic  = "p99"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb-latency-p99-high" })
}

# ─── RDS connection count alarm ───────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${local.db_instance_id}-connections-high"
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.alarm_thresholds.rds_max_connections
  evaluation_periods  = 2
  period              = 300
  statistic           = "Average"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = local.db_instance_id
  }

  tags = merge(var.tags, { Name = "${local.db_instance_id}-connections-high" })
}

# ─── Alarm notification topic ─────────────────────────────────────────────────
# Created only when the caller does not supply an existing topic ARN.
# Server-side encryption is enabled with the customer-managed key when one is
# supplied; when kms_key_arn is null the topic falls back to the AWS-managed
# SNS key (alias/aws/sns) so alarm notifications are never stored unencrypted.
resource "aws_sns_topic" "alarms" {
  count             = var.sns_topic_arn == null ? 1 : 0
  name              = "${var.name_prefix}-alarms"
  kms_master_key_id = var.kms_key_arn != null ? var.kms_key_arn : "alias/aws/sns"

  tags = merge(var.tags, { Name = "${var.name_prefix}-alarms" })
}

# ─── ECS alarms (per service) ─────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  for_each = local.alarm_services

  alarm_name          = "${each.value}-cpu-high"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.alarm_thresholds.ecs_cpu_percent
  evaluation_periods  = 3
  period              = 300
  statistic           = "Average"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    ClusterName = local.cluster_name
    ServiceName = each.value
  }

  tags = merge(var.tags, { Name = "${each.value}-cpu-high" })
}

resource "aws_cloudwatch_metric_alarm" "ecs_memory" {
  for_each = local.alarm_services

  alarm_name          = "${each.value}-memory-high"
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.alarm_thresholds.ecs_memory_percent
  evaluation_periods  = 3
  period              = 300
  statistic           = "Average"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    ClusterName = local.cluster_name
    ServiceName = each.value
  }

  tags = merge(var.tags, { Name = "${each.value}-memory-high" })
}

# ─── RDS alarms ───────────────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${local.db_instance_id}-cpu-high"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.alarm_thresholds.rds_cpu_percent
  evaluation_periods  = 3
  period              = 300
  statistic           = "Average"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = local.db_instance_id
  }

  tags = merge(var.tags, { Name = "${local.db_instance_id}-cpu-high" })
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${local.db_instance_id}-free-storage-low"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  comparison_operator = "LessThanThreshold"
  threshold           = var.alarm_thresholds.rds_free_storage_bytes
  evaluation_periods  = 1
  period              = 300
  statistic           = "Average"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = local.db_instance_id
  }

  tags = merge(var.tags, { Name = "${local.db_instance_id}-free-storage-low" })
}

# ─── ALB alarm ────────────────────────────────────────────────────────────────
# Gated on alb_arn_suffix because the ALB lives in the compute module (deployed
# after observability); wire the suffix back in once compute has applied.
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  count = var.enable_alarms && var.alb_arn_suffix != null ? 1 : 0

  alarm_name          = "${var.name_prefix}-alb-5xx-high"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.alarm_thresholds.alb_5xx_count
  evaluation_periods  = 1
  period              = 300
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb-5xx-high" })
}

# ─── Dashboard (optional) ─────────────────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "platform" {
  count          = var.enable_dashboard ? 1 : 0
  dashboard_name = "${var.name_prefix}-platform"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ECS CPU Utilization"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            for svc in values(local.services) :
            ["AWS/ECS", "CPUUtilization", "ClusterName", local.cluster_name, "ServiceName", svc]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "RDS CPU Utilization"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", local.db_instance_id]
          ]
        }
      },
    ]
  })
}

data "aws_region" "current" {}
