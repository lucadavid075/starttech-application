#!/usr/bin/env bash
# deploy-backend.sh — Build, push Docker image and trigger ASG rolling update
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPOSITORY="${ECR_REPOSITORY:?ECR_REPOSITORY not set}"
ECR_REGISTRY="${ECR_REGISTRY:?ECR_REGISTRY not set}"
ASG_NAME="${ASG_NAME:?ASG_NAME not set}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"

IMAGE_URI="$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG"

echo "▶ Logging in to ECR..."
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

echo "▶ Building Docker image: $IMAGE_URI"
docker build \
  -f Server/MuchToDo/Dockerfile \
  -t "$IMAGE_URI" \
  -t "$ECR_REGISTRY/$ECR_REPOSITORY:latest" \
  Server/MuchToDo/
echo "✓ Build complete"

echo "▶ Pushing image to ECR..."
docker push "$IMAGE_URI"
docker push "$ECR_REGISTRY/$ECR_REPOSITORY:latest"
echo "✓ Push complete"

echo "▶ Starting ASG rolling update on $ASG_NAME ..."
REFRESH_ID=$(aws autoscaling start-instance-refresh \
  --auto-scaling-group-name "$ASG_NAME" \
  --strategy Rolling \
  --preferences '{"MinHealthyPercentage":50,"InstanceWarmup":60}' \
  --query 'InstanceRefreshId' --output text)
echo "  Refresh ID: $REFRESH_ID"

echo "▶ Waiting for rolling update to complete..."
for i in $(seq 1 40); do
  STATUS=$(aws autoscaling describe-instance-refreshes \
    --auto-scaling-group-name "$ASG_NAME" \
    --instance-refresh-ids "$REFRESH_ID" \
    --query 'InstanceRefreshes[0].Status' --output text)
  PCT=$(aws autoscaling describe-instance-refreshes \
    --auto-scaling-group-name "$ASG_NAME" \
    --instance-refresh-ids "$REFRESH_ID" \
    --query 'InstanceRefreshes[0].PercentageComplete' --output text 2>/dev/null || echo "0")
  echo "  [$i/40] $STATUS — ${PCT}% complete"
  case "$STATUS" in
    Successful) echo "✓ Rolling update complete"; exit 0 ;;
    Failed|Cancelled)
      echo "✗ Rolling update $STATUS"
      aws autoscaling rollback-instance-refresh --auto-scaling-group-name "$ASG_NAME" || true
      exit 1 ;;
  esac
  sleep 30
done
echo "✗ Timed out waiting for rolling update"
exit 1
