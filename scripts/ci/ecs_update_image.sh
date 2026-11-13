#!/usr/bin/env bash
# Roll one ECS service to a new container image without Terraform: the AWS
# twin of `az containerapp update --image`, used by 220 · Fast Redeploy.
#
# Reads the service's current task definition, swaps the image of the one
# application container (the X-Ray sidecar and everything else stay as they
# are), registers the result as a new revision tagged Project=cna — the deploy
# role's ECS permissions are tag-scoped — and points the service at it with a
# forced deployment.
#
# Environment:
#   CLUSTER    ECS cluster name
#   SERVICE    ECS service name (also the task-definition family)
#   CONTAINER  container name inside the task definition (cna-api, cna-web)
#   IMAGE      new image reference
set -euo pipefail

: "${CLUSTER:?CLUSTER is required}"
: "${SERVICE:?SERVICE is required}"
: "${CONTAINER:?CONTAINER is required}"
: "${IMAGE:?IMAGE is required}"

CURRENT_TD_ARN=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].taskDefinition' --output text)
if [[ -z "$CURRENT_TD_ARN" || "$CURRENT_TD_ARN" == "None" ]]; then
  echo "::error::Service $SERVICE not found in cluster $CLUSTER (has 210 · Deploy run for this environment?)."
  exit 1
fi
echo "Current task definition: $CURRENT_TD_ARN"

# Strip the read-only attributes describe-task-definition returns, then swap the
# image. register-task-definition rejects unknown fields.
NEW_TD=$(aws ecs describe-task-definition --task-definition "$CURRENT_TD_ARN" \
  --query 'taskDefinition' --output json \
  | jq --arg name "$CONTAINER" --arg image "$IMAGE" '
      del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities,
          .registeredAt, .registeredBy, .deregisteredAt)
      | (.containerDefinitions[] | select(.name == $name) | .image) = $image')

if ! echo "$NEW_TD" | jq -e --arg name "$CONTAINER" '.containerDefinitions[] | select(.name == $name)' >/dev/null; then
  echo "::error::Container $CONTAINER not found in $CURRENT_TD_ARN."
  exit 1
fi

TMP=$(mktemp)
echo "$NEW_TD" > "$TMP"
NEW_TD_ARN=$(aws ecs register-task-definition --cli-input-json "file://$TMP" \
  --tags key=Project,value=cna \
  --query 'taskDefinition.taskDefinitionArn' --output text)
rm -f "$TMP"
echo "Registered task definition: $NEW_TD_ARN"

aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
  --task-definition "$NEW_TD_ARN" --force-new-deployment \
  --query 'service.{status: status, taskDefinition: taskDefinition}' --output table
echo "$SERVICE now rolling to $IMAGE"
