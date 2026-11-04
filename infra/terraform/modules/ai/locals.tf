locals {
  # Foundation model IDs are regional; explicit Bedrock ARNs may also identify
  # system-defined inference profiles for models served only through a profile.
  model_source_arns = [
    for m in var.model_ids :
    startswith(trimspace(m), "arn:")
    ? trimspace(m)
    : "arn:${data.aws_partition.current.partition}:bedrock:${data.aws_region.current.name}::foundation-model/${trimspace(m)}"
  ]

  # The primary model/profile source (first in the list) for the application profile.
  chat_model_arn = local.model_source_arns[0]

  # Inference profile name follows the Azure deployment naming convention:
  # a stable, human-readable name the app references.
  inference_profile_name = "${var.name_prefix}-${var.chat_profile_name}"

  # All ARNs that the task role should be allowed to invoke:
  # foundation models + any provisioned throughput ARN + inference profile ARN.
  provisioned_arns = var.enable_provisioned_throughput ? [
    "arn:${data.aws_partition.current.partition}:bedrock:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:provisioned-model/${var.name_prefix}-chat-pmt"
  ] : []

  inference_profile_arns = var.enable_inference_profile ? [
    "arn:${data.aws_partition.current.partition}:bedrock:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:inference-profile/${local.inference_profile_name}"
  ] : []

  all_invocable_arns = concat(
    local.model_source_arns,
    local.provisioned_arns,
    local.inference_profile_arns,
  )
}
