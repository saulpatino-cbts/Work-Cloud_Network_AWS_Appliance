variable "name_prefix" {
  description = "Normalized name prefix for AI resources (e.g. cna-dev-use1)"
  type        = string
}

variable "tags" {
  description = "Tags applied to AI resources"
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "environment" {
  description = "Deployment environment (dev or prod). Used in resource descriptions."
  type        = string
  default     = "dev"
}

variable "model_ids" {
  description = "Customer-selected Bedrock foundation model ID or source ARN. A foundation-model ARN or system-defined inference-profile ARN is accepted; the first entry is used as the inference-profile source. Confirm model/profile availability and access for the target Region and account before deployment."
  type        = list(string)
  nullable    = false

  validation {
    condition = length(var.model_ids) > 0 && alltrue([
      for model_id in var.model_ids :
      can(regex("^[A-Za-z0-9][A-Za-z0-9._:-]*$", trimspace(model_id))) ||
      can(regex("^arn:[a-z0-9-]+:bedrock:[a-z0-9-]+:(|[0-9]{12}|aws):(foundation-model|inference-profile)/[A-Za-z0-9._:/-]+$", trimspace(model_id)))
    ])
    error_message = "Provide at least one Bedrock model ID or a Bedrock foundation-model/inference-profile ARN."
  }
}

variable "chat_profile_name" {
  description = "Suffix for the inference profile name. The full name is '{name_prefix}-{chat_profile_name}'. Mirrors Azure's AZURE_OPENAI_DEPLOYMENT concept — a stable name the application references."
  type        = string
  default     = "chat-latest"
}

variable "enable_inference_profile" {
  description = "Create a Bedrock application inference profile (mirrors Azure's cognitive_deployment). Provides a stable endpoint name for model routing."
  type        = bool
  default     = true
}

variable "enable_provisioned_throughput" {
  description = "Create Bedrock provisioned model throughput (mirrors Azure deployment capacity/SKU). Provides dedicated throughput for predictable latency. Disabled by default (on-demand); enable in prod."
  type        = bool
  default     = false
}

variable "provisioned_model_units" {
  description = "Number of provisioned model units (PMUs). Each unit provides a fixed throughput capacity. Only used when enable_provisioned_throughput is true."
  type        = number
  default     = 1
}

variable "enable_guardrail" {
  description = "Create a Bedrock guardrail for content filtering."
  type        = bool
  default     = false
}
