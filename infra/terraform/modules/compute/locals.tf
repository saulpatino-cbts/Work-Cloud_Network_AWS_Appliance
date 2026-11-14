locals {
  cluster_name = "${var.name_prefix}-cluster"

  api_service_name = "${var.name_prefix}-api"
  web_service_name = "${var.name_prefix}-web"

  # Container names are load-bearing: the service load_balancer block references
  # them, so they must match the container_definitions name exactly.
  api_container_name = "cna-api"
  web_container_name = "cna-web"

  # HTTPS listener exists only when a cert ARN is supplied — an ACM cert is
  # created/validated externally (spec §12.2).
  https_enabled = var.alb_certificate_arn != null

  # Service Connect: the api publishes its named port under this discovery
  # name, so web tasks reach it at http://api:<api_target_port>. The URL is
  # injected into the web container as CNA_API_INTERNAL_URL (core contract).
  api_discovery_name = "api"
  api_internal_url   = "http://${local.api_discovery_name}:${var.api_target_port}"

  # The api and web services are target-tracking scaled and cannot come back
  # from zero (no metric datapoints without tasks), so their floor is always
  # at least one task.
  api_desired_count = max(1, var.api_min_count)
  web_desired_count = max(1, var.web_min_count)

  # Container-definition env/secret shapes derived from the input maps.
  api_environment = [for k, v in var.api_environment : { name = k, value = v }]
  web_environment = [
    for k, v in merge(var.web_environment, { CNA_API_INTERNAL_URL = local.api_internal_url }) : { name = k, value = v }
  ]

  api_secrets = [for k, arn in var.api_secrets : { name = k, valueFrom = arn }]
  web_secrets = [for k, arn in var.web_secrets : { name = k, valueFrom = arn }]

  repository_credentials = var.dockerhub_secret_arn != null ? { credentialsParameter = var.dockerhub_secret_arn } : null

  # X-Ray daemon sidecar container definition (injected into each task when enabled).
  xray_sidecar = var.enable_xray ? {
    name      = "xray-daemon"
    image     = var.xray_daemon_image
    essential = false
    cpu       = 32
    memory    = 64
    portMappings = [
      { containerPort = 2000, protocol = "udp" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = var.xray_log_group_name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "xray"
      }
    }
  } : null

  # Environment variable injected into application containers to point SDK at local daemon.
  xray_env_var = var.enable_xray ? [{ name = "AWS_XRAY_DAEMON_ADDRESS", value = "127.0.0.1:2000" }] : []
}
