output "task_bedrock_policy_json" {
  description = "IAM policy JSON granting bedrock:InvokeModel on the configured model/profile source, application inference profile, and provisioned throughput. Consumed by the identity module and attached to the ECS task role."
  value       = data.aws_iam_policy_document.bedrock_invoke.json
}

output "inference_profile_arn" {
  description = "Bedrock inference profile ARN, or null when the profile is disabled. The application should invoke this ARN instead of the raw model ARN for stable routing."
  value       = one(aws_bedrock_inference_profile.chat[*].arn)
}

output "inference_profile_id" {
  description = "Bedrock inference profile ID, or null when the profile is disabled."
  value       = one(aws_bedrock_inference_profile.chat[*].id)
}

output "inference_profile_name" {
  description = "Bedrock inference profile name (app-facing stable identifier), or null when disabled."
  value       = var.enable_inference_profile ? local.inference_profile_name : null
}

output "provisioned_model_arn" {
  description = "Bedrock provisioned model throughput ARN, or null when disabled."
  value       = one(aws_bedrock_provisioned_model_throughput.chat[*].provisioned_model_arn)
}

output "guardrail_id" {
  description = "Bedrock guardrail ID, or null when enable_guardrail is false."
  value       = one(aws_bedrock_guardrail.this[*].guardrail_id)
}

output "guardrail_arn" {
  description = "Bedrock guardrail ARN, or null when enable_guardrail is false."
  value       = one(aws_bedrock_guardrail.this[*].guardrail_arn)
}

output "chat_model_arn" {
  description = "Bedrock ARN for the customer-selected foundation model or system-defined inference-profile source."
  value       = local.chat_model_arn
}
