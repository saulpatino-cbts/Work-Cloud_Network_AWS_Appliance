variable "name_prefix" {
  description = "Normalized name prefix for compute resources (e.g. cna-dev-use1)"
  type        = string
}

variable "tags" {
  description = "Tags applied to compute resources"
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "aws_region" {
  description = "AWS region — used for the awslogs log configuration region."
  type        = string
}

# ─── Networking (from the platform environment) ───────────────────────────────
variable "vpc_id" {
  description = "VPC ID for the ALB target groups."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the internet-facing ALB."
  type        = list(string)
  nullable    = false
}

variable "app_subnet_ids" {
  description = "Application (private) subnet IDs for the ECS Fargate tasks."
  type        = list(string)
  nullable    = false
}

variable "alb_security_group_id" {
  description = "Security group ID for the ALB."
  type        = string
}

variable "app_security_group_id" {
  description = "Security group ID for the ECS tasks. This module adds a self-referencing ingress rule on api_target_port for the web -> api Service Connect path."
  type        = string
}

# ─── Identity (from the identity module) ──────────────────────────────────────
variable "task_execution_role_arn" {
  description = "ECS task execution role ARN (image pull, log write, secret fetch)."
  type        = string
}

variable "task_role_arn" {
  description = "ECS task role ARN (application identity)."
  type        = string
}

# ─── TLS ──────────────────────────────────────────────────────────────────────
variable "alb_certificate_arn" {
  description = "ACM certificate ARN (in the ALB's region) for the HTTPS listener. Null skips the HTTPS listener. The certificate is created and validated externally — this module never mints one (spec §12.2)."
  type        = string
  default     = null
}

# ─── Container images ─────────────────────────────────────────────────────────
# Pinned references supplied by the workload root (from 210 · Deploy). No
# default: a floating placeholder would plan cleanly and pull the wrong image.
variable "api_image" {
  description = "Container image for CNA API, pinned: docker.io/<namespace>/cna:api-sha-<7>@sha256:<digest>"
  type        = string
}

variable "web_image" {
  description = "Container image for CNA Web (Next.js 15), pinned: docker.io/<namespace>/cna:web-sha-<7>@sha256:<digest>"
  type        = string
}

# ─── Task sizing ──────────────────────────────────────────────────────────────
variable "api_cpu" {
  description = "CPU units for the API task (1024 = 1 vCPU)."
  type        = number
  default     = 512
}

variable "api_memory" {
  description = "Memory (MiB) for the API task."
  type        = number
  default     = 1024
}

variable "web_cpu" {
  description = "CPU units for the web task (1024 = 1 vCPU)."
  type        = number
  default     = 512
}

variable "web_memory" {
  description = "Memory (MiB) for the web task."
  type        = number
  default     = 1024
}

# ─── Scaling ──────────────────────────────────────────────────────────────────
variable "api_min_count" {
  description = "Baseline desired task count for the API service."
  type        = number
  default     = 1
}

variable "web_min_count" {
  description = "Baseline desired task count for the web service."
  type        = number
  default     = 1
}

# ─── Ingress ports ────────────────────────────────────────────────────────────
variable "api_target_port" {
  description = "Container port for the API service; published through Service Connect as http://api:<port> and opened on the app security group for task-to-task traffic."
  type        = number
  default     = 8080
}

variable "web_target_port" {
  description = "Container/target-group port for the web service (Next.js)."
  type        = number
  default     = 3000
}

# ─── Environment + secrets ────────────────────────────────────────────────────
variable "api_environment" {
  description = "Plain environment variables for the API container. Map key is the env var name."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "web_environment" {
  description = "Plain environment variables for the web container. Map key is the env var name."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "api_secrets" {
  description = "Secret-backed env vars for the API container. Map key is the env var name, value is the Secrets Manager secret ARN."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "web_secrets" {
  description = "Secret-backed env vars for the web container. Map key is the env var name, value is the Secrets Manager secret ARN."
  type        = map(string)
  default     = {}
  nullable    = false
}

# ─── Logging ──────────────────────────────────────────────────────────────────
variable "api_log_group_name" {
  description = "CloudWatch log group name for the API service (owned by the observability module)."
  type        = string
}

variable "web_log_group_name" {
  description = "CloudWatch log group name for the web service (owned by the observability module)."
  type        = string
}

# ─── Private registry ─────────────────────────────────────────────────────────
variable "dockerhub_secret_arn" {
  description = "Secrets Manager ARN holding Docker Hub credentials for private image pulls. Null omits repositoryCredentials. Supplied by the runtime module."
  type        = string
  default     = null
}

# ─── Tracing (X-Ray) ─────────────────────────────────────────────────────────
variable "enable_xray" {
  description = "Inject the X-Ray daemon sidecar into each task definition. Mirrors Azure Application Insights distributed tracing."
  type        = bool
  default     = false
}

variable "xray_daemon_image" {
  description = "X-Ray daemon sidecar image, pinned to a published release tag so a task-definition rebuild never silently changes the daemon (public.ecr.aws/xray/aws-xray-daemon). Bump deliberately; never a floating tag."
  type        = string
  default     = "public.ecr.aws/xray/aws-xray-daemon:3.7.0"

  validation {
    condition     = !endswith(var.xray_daemon_image, ":latest") && strcontains(var.xray_daemon_image, ":")
    error_message = "xray_daemon_image must carry an explicit, non-floating tag (not :latest)."
  }
}

variable "xray_log_group_name" {
  description = "CloudWatch log group name for the X-Ray daemon sidecar (from observability module). Required when enable_xray is true."
  type        = string
  default     = ""
}

# ─── Autoscaling ──────────────────────────────────────────────────────────────
variable "enable_autoscaling" {
  description = "Create Application Auto Scaling targets and policies for all ECS services. Mirrors Azure Container Apps' built-in scaling."
  type        = bool
  default     = true
}

variable "api_max_count" {
  description = "Maximum task count for the API service."
  type        = number
  default     = 4
}

variable "web_max_count" {
  description = "Maximum task count for the web service."
  type        = number
  default     = 4
}

variable "autoscaling_cpu_target_percent" {
  description = "Target CPU utilization percentage for scale-out."
  type        = number
  default     = 70
}

variable "autoscaling_memory_target_percent" {
  description = "Target memory utilization percentage for scale-out."
  type        = number
  default     = 80
}

variable "autoscaling_requests_per_target" {
  description = "Target ALB request count per task for scale-out (web). Mirrors Azure Container Apps' HTTP concurrency trigger."
  type        = number
  default     = 100
}

variable "autoscaling_scale_in_cooldown" {
  description = "Cooldown period (seconds) after a scale-in before another scale-in can occur."
  type        = number
  default     = 300
}

variable "autoscaling_scale_out_cooldown" {
  description = "Cooldown period (seconds) after a scale-out before another scale-out can occur."
  type        = number
  default     = 60
}
