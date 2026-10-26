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

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.40.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones for the subnets, aligned by index with the subnet CIDR lists. Empty (the default) derives them from the region at plan time: the first N available zones, N = the number of subnet CIDRs. Set explicitly only to pin zones."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "subnet_public_cidrs" {
  description = "CIDR blocks for the public subnets (ALB, NAT gateways), one per AZ."
  type        = list(string)
  default     = ["10.40.0.0/24", "10.40.1.0/24"]
  nullable    = false
}

variable "subnet_app_cidrs" {
  description = "CIDR blocks for the application (private) subnets (ECS tasks), one per AZ."
  type        = list(string)
  default     = ["10.40.10.0/24", "10.40.11.0/24"]
  nullable    = false
}

variable "subnet_database_cidrs" {
  description = "CIDR blocks for the database subnets (RDS), one per AZ."
  type        = list(string)
  default     = ["10.40.20.0/24", "10.40.21.0/24"]
  nullable    = false
}

variable "single_nat_gateway" {
  description = "Use a single shared NAT gateway (dev cost saving) instead of one per AZ (prod HA)."
  type        = bool
  default     = false
}

variable "flow_log_retention_days" {
  description = "Retention, in days, for the VPC flow-log CloudWatch log group."
  type        = number
  default     = 30
}

variable "enable_vpc_endpoints" {
  description = "Create VPC endpoints for S3, DynamoDB, Secrets Manager, CloudWatch Logs, Bedrock, STS and X-Ray (plus ECR when enable_ecr_endpoints is set). Keeps service traffic within the VPC (mirrors Azure private endpoints). Enabled by default."
  type        = bool
  default     = true
}

variable "enable_ecr_endpoints" {
  description = "Also create the two ECR interface endpoints (ecr.api, ecr.dkr). Off by default: the appliance pulls its images from Docker Hub and the X-Ray daemon from ECR Public, neither of which these endpoints serve, so they would only add an hourly charge per AZ. Turn on if images are ever mirrored into a private ECR registry."
  type        = bool
  default     = false
}
