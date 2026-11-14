# =============================================================================
# Compute — ECS Fargate cluster, task definitions, services, and the ALB
# (source: migrate/ecs.tf, migrate/alb.tf). Mirrors the Azure compute module
# (Container Apps + built-in ingress). The ALB lives here because ingress is a
# compute concern, matching Container Apps' internal ingress.
#
# Only the web service sits behind the ALB. The api is reached exclusively
# over ECS Service Connect (Cloud Map HTTP namespace, DNS name `api`) from the
# web tasks — the AWS twin of the Azure sibling's internal-ingress api
# Container App. It is never attached to the public listener.
# =============================================================================

# ─── ECS cluster ──────────────────────────────────────────────────────────────
resource "aws_ecs_cluster" "this" {
  name = local.cluster_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(var.tags, { Name = local.cluster_name })
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

# ─── Task definitions ─────────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "api" {
  family                   = local.api_service_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.api_cpu
  memory                   = var.api_memory
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode(compact([
    jsonencode(merge(
      {
        name      = local.api_container_name
        image     = var.api_image
        essential = true
        # The port mapping is named so Service Connect can publish it as `api`.
        portMappings = [{ name = local.api_discovery_name, containerPort = var.api_target_port, protocol = "tcp", appProtocol = "http" }]
        environment  = concat(local.api_environment, local.xray_env_var)
        secrets      = local.api_secrets

        logConfiguration = {
          logDriver = "awslogs"
          options = {
            "awslogs-group"         = var.api_log_group_name
            "awslogs-region"        = var.aws_region
            "awslogs-stream-prefix" = "api"
          }
        }

        # ECS has a single container health check, so it is the liveness probe
        # (`/health`, a pure "process is up" answer). The image ships no curl —
        # the probe uses the interpreter it already has (mirrors the image's own
        # HEALTHCHECK). The api also exposes `GET /ready` (runs `SELECT 1`;
        # 503 until the database answers): it is the readiness probe to point
        # an internal load balancer's target group at if one is ever put in
        # front of the api. Today no LB fronts the api, so nothing consumes it.
        healthCheck = {
          command     = ["CMD-SHELL", "python -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:${var.api_target_port}/health',timeout=5).status<500 else 1)\""]
          interval    = 30
          timeout     = 5
          retries     = 3
          startPeriod = 60
        }
      },
      local.repository_credentials != null ? { repositoryCredentials = local.repository_credentials } : {}
    )),
    local.xray_sidecar != null ? jsonencode(local.xray_sidecar) : "",
  ]))

  tags = merge(var.tags, { Name = local.api_service_name })
}

resource "aws_ecs_task_definition" "web" {
  family                   = local.web_service_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.web_cpu
  memory                   = var.web_memory
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode(compact([
    jsonencode(merge(
      {
        name         = local.web_container_name
        image        = var.web_image
        essential    = true
        portMappings = [{ containerPort = var.web_target_port, protocol = "tcp" }]
        environment  = concat(local.web_environment, local.xray_env_var)
        secrets      = local.web_secrets

        logConfiguration = {
          logDriver = "awslogs"
          options = {
            "awslogs-group"         = var.web_log_group_name
            "awslogs-region"        = var.aws_region
            "awslogs-stream-prefix" = "web"
          }
        }

        # Liveness via node (the runtime image has no curl); `/api/health`
        # returns 503 while the database is unreachable, so pass on any status
        # below 500 to keep a database blip from restarting the web tier.
        healthCheck = {
          command     = ["CMD-SHELL", "node -e \"fetch('http://127.0.0.1:${var.web_target_port}/api/health').then(r=>process.exit(r.status<500?0:1)).catch(()=>process.exit(1))\""]
          interval    = 30
          timeout     = 5
          retries     = 3
          startPeriod = 60
        }
      },
      local.repository_credentials != null ? { repositoryCredentials = local.repository_credentials } : {}
    )),
    local.xray_sidecar != null ? jsonencode(local.xray_sidecar) : "",
  ]))

  tags = merge(var.tags, { Name = local.web_service_name })
}

# ─── Application Load Balancer ────────────────────────────────────────────────
resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  # Strip HTTP headers the ALB considers malformed instead of forwarding them to
  # the tasks — defends the app tier against request-smuggling / header-injection
  # attempts. Account-independent hardening (no live resource required).
  drop_invalid_header_fields = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb" })
}

resource "aws_lb_target_group" "web" {
  name        = "${var.name_prefix}-web"
  port        = var.web_target_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/api/health"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-tg-web" })
}

# ─── Listeners ────────────────────────────────────────────────────────────────
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = local.https_enabled ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.alb_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# ─── Service Connect (private web → api path) ─────────────────────────────────
# Cloud Map HTTP namespace the api publishes itself into and the web tasks
# resolve from. The api is reachable as http://api:<api_target_port> from any
# task whose service is a Service Connect client in this namespace (web only).
# Replaces the former public ALB path rule for the
# api, which exposed /health, /metrics, /chat and /api/v1/* to the internet.
resource "aws_service_discovery_http_namespace" "this" {
  name        = var.name_prefix
  description = "ECS Service Connect namespace for ${var.name_prefix}"

  tags = merge(var.tags, { Name = var.name_prefix })
}

# Task-to-task traffic on the api port. The app security group is created by
# the platform root with ALB-only ingress; this rule lets the web tasks' Service
# Connect proxy reach the api tasks on the same security group. It lives here,
# with the service that needs it, so it is created and destroyed with it.
resource "aws_vpc_security_group_ingress_rule" "app_to_api" {
  security_group_id            = var.app_security_group_id
  description                  = "api port from the app tier itself (Service Connect web -> api)"
  referenced_security_group_id = var.app_security_group_id
  from_port                    = var.api_target_port
  to_port                      = var.api_target_port
  ip_protocol                  = "tcp"

  tags = merge(var.tags, { Name = "${var.name_prefix}-sgr-app-to-api" })
}

# ─── Services ─────────────────────────────────────────────────────────────────
resource "aws_ecs_service" "api" {
  name                  = local.api_service_name
  cluster               = aws_ecs_cluster.this.id
  task_definition       = aws_ecs_task_definition.api.arn
  desired_count         = local.api_desired_count
  launch_type           = "FARGATE"
  wait_for_steady_state = true

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [var.app_security_group_id]
    assign_public_ip = false
  }

  # Publishes the api's named port as `api` in the namespace; Service Connect
  # injects the proxy sidecar and registers the tasks in Cloud Map.
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.this.arn

    log_configuration {
      log_driver = "awslogs"
      options = {
        "awslogs-group"         = var.api_log_group_name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "service-connect"
      }
    }

    service {
      port_name      = local.api_discovery_name
      discovery_name = local.api_discovery_name

      client_alias {
        port     = var.api_target_port
        dns_name = local.api_discovery_name
      }
    }
  }

  # desired_count is managed by application autoscaling, not by Terraform,
  # once the service is running.
  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [aws_vpc_security_group_ingress_rule.app_to_api]
}

resource "aws_ecs_service" "web" {
  name            = local.web_service_name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.web.arn
  desired_count   = local.web_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [var.app_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.web.arn
    container_name   = local.web_container_name
    container_port   = var.web_target_port
  }

  # Client-only enrolment (no `service` block): the web tasks get the Service
  # Connect proxy and can resolve `api`, but publish nothing themselves.
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.this.arn

    log_configuration {
      log_driver = "awslogs"
      options = {
        "awslogs-group"         = var.web_log_group_name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "service-connect"
      }
    }
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  # Create web only after the API service has reached steady state so a cold
  # apply does not start web tasks before the Service Connect API endpoint exists.
  depends_on = [
    aws_ecs_service.api,
    aws_lb_listener.https,
    aws_vpc_security_group_ingress_rule.app_to_api,
  ]
}

# =============================================================================
# Application Auto Scaling — mirrors Azure Container Apps' min/max replica
# scaling with target tracking on CPU and memory (plus ALB requests for web).
# Target tracking cannot scale a service out from zero (no datapoints with no
# tasks), so the api and web floors never drop below one task.
# =============================================================================

# ─── API service autoscaling ──────────────────────────────────────────────────
resource "aws_appautoscaling_target" "api" {
  count = var.enable_autoscaling ? 1 : 0

  max_capacity       = var.api_max_count
  min_capacity       = local.api_desired_count
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "api_cpu" {
  count = var.enable_autoscaling ? 1 : 0

  name               = "${local.api_service_name}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.api[0].resource_id
  scalable_dimension = aws_appautoscaling_target.api[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.api[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = var.autoscaling_cpu_target_percent
    scale_in_cooldown  = var.autoscaling_scale_in_cooldown
    scale_out_cooldown = var.autoscaling_scale_out_cooldown
  }
}

resource "aws_appautoscaling_policy" "api_memory" {
  count = var.enable_autoscaling ? 1 : 0

  name               = "${local.api_service_name}-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.api[0].resource_id
  scalable_dimension = aws_appautoscaling_target.api[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.api[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = var.autoscaling_memory_target_percent
    scale_in_cooldown  = var.autoscaling_scale_in_cooldown
    scale_out_cooldown = var.autoscaling_scale_out_cooldown
  }
}

# ─── Web service autoscaling ──────────────────────────────────────────────────
resource "aws_appautoscaling_target" "web" {
  count = var.enable_autoscaling ? 1 : 0

  max_capacity       = var.web_max_count
  min_capacity       = local.web_desired_count
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.web.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "web_cpu" {
  count = var.enable_autoscaling ? 1 : 0

  name               = "${local.web_service_name}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.web[0].resource_id
  scalable_dimension = aws_appautoscaling_target.web[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.web[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = var.autoscaling_cpu_target_percent
    scale_in_cooldown  = var.autoscaling_scale_in_cooldown
    scale_out_cooldown = var.autoscaling_scale_out_cooldown
  }
}

resource "aws_appautoscaling_policy" "web_memory" {
  count = var.enable_autoscaling ? 1 : 0

  name               = "${local.web_service_name}-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.web[0].resource_id
  scalable_dimension = aws_appautoscaling_target.web[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.web[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = var.autoscaling_memory_target_percent
    scale_in_cooldown  = var.autoscaling_scale_in_cooldown
    scale_out_cooldown = var.autoscaling_scale_out_cooldown
  }
}

# ─── ALB request count scaling (web) ──────────────────────────────────────────
# Mirrors Azure Container Apps' HTTP concurrency scaling trigger. Only the web
# service is an ALB target; the api scales on CPU/memory alone.
resource "aws_appautoscaling_policy" "web_alb_requests" {
  count = var.enable_autoscaling ? 1 : 0

  name               = "${local.web_service_name}-alb-requests"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.web[0].resource_id
  scalable_dimension = aws_appautoscaling_target.web[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.web[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.this.arn_suffix}/${aws_lb_target_group.web.arn_suffix}"
    }
    target_value       = var.autoscaling_requests_per_target
    scale_in_cooldown  = var.autoscaling_scale_in_cooldown
    scale_out_cooldown = var.autoscaling_scale_out_cooldown
  }
}
