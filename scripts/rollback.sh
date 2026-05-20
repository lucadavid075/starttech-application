#!/usr/bin/env bash
# rollback.sh — Rollback to a previous Docker image tag or cancel ASG refresh
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ASG_NAME="${ASG_NAME:?ASG_NAME not set}"
ECR_REGISTRY="${ECR_REGISTRY:?ECR_REGISTRY not set}"
ECR_REPOSITORY="${ECR_REPOSITORY:?ECR_REPOSITORY not set}"
ROLLBACK_TAG="${1:?Usage: $0 <image-tag-to-rollback-to>}"

echo "⚠️  Rolling back to image tag: $ROLLBACK_TAG"

# Check if an in-progress refresh is running; cancel it first
IN_PROGRESS=$(aws autoscaling describe-instance-refreshes \
  --auto-scaling-group-name "$ASG_NAME" \
  --query 'InstanceRefreshes[?Status==`InProgress`].InstanceRefreshId' \
  --output text)
if [ -n "$IN_PROGRESS" ] && [ "$IN_PROGRESS" != "None" ]; then
  echo "▶ Cancelling in-progress refresh $IN_PROGRESS ..."
  aws autoscaling cancel-instance-refresh --auto-scaling-group-name "$ASG_NAME"
  sleep 10
fi

# Re-tag old image as latest
ROLLBACK_URI="$ECR_REGISTRY/$ECR_REPOSITORY:$ROLLBACK_TAG"
LATEST_URI="$ECR_REGISTRY/$ECR_REPOSITORY:latest"

echo "▶ Logging in to ECR..."
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

echo "▶ Pulling rollback image $ROLLBACK_URI ..."
docker pull "$ROLLBACK_URI"
docker tag "$ROLLBACK_URI" "$LATEST_URI"
docker push "$LATEST_URI"
echo "✓ latest re-tagged to $ROLLBACK_TAG"

echo "▶ Starting rollback rolling update..."
REFRESH_ID=$(aws autoscaling start-instance-refresh \
  --auto-scaling-group-name "$ASG_NAME" \
  --strategy Rolling \
  --preferences '{"MinHealthyPercentage":50,"InstanceWarmup":60}' \
  --query 'InstanceRefreshId' --output text)
echo "  Refresh ID: $REFRESH_ID"

for i in $(seq 1 40); do
  STATUS=$(aws autoscaling describe-instance-refreshes \
    --auto-scaling-group-name "$ASG_NAME" \
    --instance-refresh-ids "$REFRESH_ID" \
    --query 'InstanceRefreshes[0].Status' --output text)
  echo "  [$i/40] $STATUS"
  case "$STATUS" in
    Successful) echo "✅ Rollback complete"; exit 0 ;;
    Failed|Cancelled) echo "✗ Rollback $STATUS"; exit 1 ;;
  esac
  sleep 30
done
echo "✗ Timed out waiting for rollback"
exit 1
