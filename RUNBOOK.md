# Operations Runbook

## Health Checks

```bash
# ALB health
curl -f http://<ALB_DNS>/health

# CloudFront health
curl -f https://<CF_DOMAIN>

# Check running containers on an EC2 instance (via SSM)
aws ssm start-session --target <instance-id>
# Then:
docker ps
docker logs starttech-backend --tail 100
```

## Deployments

### Trigger a Deploy
Push to `main` — both pipelines auto-trigger based on changed paths.

### Manual Frontend Deploy
```bash
export FRONTEND_BUCKET_NAME="starttech-frontend-prod"
export CLOUDFRONT_DISTRIBUTION_ID="E1XXXXXXXXXXXXX"
export VITE_API_BASE_URL="http://your-alb.us-east-1.elb.amazonaws.com"
./scripts/deploy-frontend.sh
```

### Manual Backend Deploy
```bash
export ECR_REGISTRY="123456789012.dkr.ecr.us-east-1.amazonaws.com"
export ECR_REPOSITORY="starttech-backend"
export ASG_NAME="starttech-prod-asg"
./scripts/deploy-backend.sh
```

## Rollback Procedures

### Frontend Rollback
S3 bucket has versioning enabled. List and restore a previous object version:
```bash
# List versions of index.html
aws s3api list-object-versions \
  --bucket starttech-frontend-prod \
  --prefix index.html

# Restore specific version
aws s3api copy-object \
  --bucket starttech-frontend-prod \
  --copy-source "starttech-frontend-prod/index.html?versionId=<VERSION_ID>" \
  --key index.html

# Invalidate CloudFront
aws cloudfront create-invalidation \
  --distribution-id $CLOUDFRONT_DISTRIBUTION_ID \
  --paths "/*"
```

### Backend Rollback
```bash
# Roll back to a previous Git SHA image
export ASG_NAME="starttech-prod-asg"
export ECR_REGISTRY="123456789012.dkr.ecr.us-east-1.amazonaws.com"
export ECR_REPOSITORY="starttech-backend"
./scripts/rollback.sh <previous-git-sha>
```

### Cancel In-Progress Deploy
```bash
aws autoscaling cancel-instance-refresh \
  --auto-scaling-group-name starttech-prod-asg
```

## Scaling

```bash
# Manually adjust ASG desired capacity
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name starttech-prod-asg \
  --desired-capacity 3

# View current ASG state
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names starttech-prod-asg \
  --query 'AutoScalingGroups[0].{
    Desired:DesiredCapacity,
    Min:MinSize,
    Max:MaxSize,
    Instances:Instances[*].InstanceId
  }'
```

## Logs

```bash
# Tail backend logs (last 5 minutes)
aws logs filter-log-events \
  --log-group-name /starttech/prod/backend \
  --start-time $(date -d '5 minutes ago' +%s000) \
  --filter-pattern "ERROR"

# Or use Log Insights queries in monitoring/log-insights-queries.txt
# AWS Console → CloudWatch → Log Insights → paste query
```

## Common Issues

| Symptom | Check | Fix |
|---------|-------|-----|
| 502 Bad Gateway | EC2 health in target group | Check `docker ps` on instance; check port 8080 |
| Slow deploys | ASG instance warmup | Check `/health` endpoint; increase warmup seconds |
| Redis connection refused | Security group + Redis endpoint | Verify SG allows 6379 from backend SG |
| MongoDB connection errors | Atlas IP whitelist | Add NAT Gateway EIPs to Atlas IP whitelist |
| CloudFront serving stale content | Invalidation not complete | Run `aws cloudfront create-invalidation --paths "/*"` |
| High memory on EC2 | Container memory leak | `docker stats` on instance; set memory limit in run command |

## MongoDB Atlas — IP Whitelist
EC2 instances egress through NAT Gateway. Add the NAT Gateway EIPs to MongoDB Atlas → Network Access → IP Whitelist.

Get EIPs:
```bash
aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=starttech-prod-nat-eip-*" \
  --query 'Addresses[*].PublicIp' \
  --output text
```
