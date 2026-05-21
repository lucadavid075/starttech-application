# Operations Runbook — MuchToDo (StartTech)

## Quick Reference

| Resource | Value |
|---|---|
| ALB DNS | `starttech-prod-alb-573464244.us-east-1.elb.amazonaws.com` |
| CloudFront | `https://dr6pmr4bkrgm4.cloudfront.net` |
| S3 Bucket | `starttech-frontend-prod-114324232512` |
| ECR | `757559216958.dkr.ecr.us-east-1.amazonaws.com/starttech-backend` |
| ASG | `starttech-prod-asg` |
| CloudFront ID | `E2YNKCD0KTWGSA` |
| Log Group | `/starttech/prod/backend` |
| Redis | `starttech-prod-redis.nzwttl.0001.use1.cache.amazonaws.com:6379` |
| MongoDB | `starttech-prod.3w7lwzq.mongodb.net` |
| Region | `us-east-1` |
| AWS Account | `757559216958` |

---

## Health Checks

```bash
# Backend via ALB
curl -f http://starttech-prod-alb-573464244.us-east-1.elb.amazonaws.com/health
# Expected: {"cache":"ok","database":"ok"}

# Frontend via CloudFront
curl -f https://dr6pmr4bkrgm4.cloudfront.net
# Expected: HTTP 200

# Use the health-check script
./scripts/health-check.sh http://starttech-prod-alb-573464244.us-east-1.elb.amazonaws.com

# Check running containers on an EC2 instance (via SSM — no SSH needed)
aws ssm start-session --target <instance-id>
# Then inside the session:
docker ps
docker logs starttech-backend --tail 100
docker stats starttech-backend --no-stream

# List healthy instances in target group
aws elbv2 describe-target-health \
  --target-group-arn arn:aws:elasticloadbalancing:us-east-1:757559216958:targetgroup/starttech-prod-tg/e7301267157c1873 \
  --query 'TargetHealthDescriptions[*].{ID:Target.Id,Port:Target.Port,State:TargetHealth.State}'

# View ASG current state
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names starttech-prod-asg \
  --query 'AutoScalingGroups[0].{Desired:DesiredCapacity,Min:MinSize,Max:MaxSize,Instances:Instances[*].{ID:InstanceId,State:LifecycleState,Health:HealthStatus}}'
```

---

## Deployments

### Trigger a Deploy (Normal Flow)
Push to `main` — both pipelines auto-trigger based on changed paths:
- `backend/**` → backend pipeline (test → build → push ECR → rolling ASG update)
- `frontend/**` → frontend pipeline (build → S3 sync → CloudFront invalidation)

### Manual Frontend Deploy
```bash
export FRONTEND_BUCKET_NAME="starttech-frontend-prod-114324232512"
export CLOUDFRONT_DISTRIBUTION_ID="E2YNKCD0KTWGSA"
export VITE_API_BASE_URL="http://starttech-prod-alb-573464244.us-east-1.elb.amazonaws.com"

cd frontend && npm ci
VITE_API_BASE_URL="$VITE_API_BASE_URL" npm run build

# HTML — no cache
aws s3 sync dist/ "s3://$FRONTEND_BUCKET_NAME" \
  --exclude "*" --include "*.html" \
  --cache-control "no-cache, no-store, must-revalidate" \
  --delete

# Hashed assets — immutable
aws s3 sync dist/ "s3://$FRONTEND_BUCKET_NAME" \
  --exclude "*.html" \
  --cache-control "public, max-age=31536000, immutable" \
  --delete

# Invalidate CloudFront
INV_ID=$(aws cloudfront create-invalidation \
  --distribution-id "$CLOUDFRONT_DISTRIBUTION_ID" \
  --paths "/*" \
  --query 'Invalidation.Id' --output text)
aws cloudfront wait invalidation-completed \
  --distribution-id "$CLOUDFRONT_DISTRIBUTION_ID" --id "$INV_ID"
echo "Done: $INV_ID"
```

### Manual Backend Deploy
```bash
export ECR_REGISTRY="757559216958.dkr.ecr.us-east-1.amazonaws.com"
export ECR_REPOSITORY="starttech-backend"
export ASG_NAME="starttech-prod-asg"
export IMAGE_TAG=$(git rev-parse --short HEAD)

./scripts/deploy-backend.sh
```

---

## Rollback Procedures

### Frontend Rollback
S3 bucket has versioning enabled. To restore a previous version of `index.html`:

```bash
# List versions
aws s3api list-object-versions \
  --bucket starttech-frontend-prod-114324232512 \
  --prefix index.html \
  --query 'Versions[*].{VersionId:VersionId,LastModified:LastModified}'

# Restore specific version
aws s3api copy-object \
  --bucket starttech-frontend-prod-114324232512 \
  --copy-source "starttech-frontend-prod-114324232512/index.html?versionId=<VERSION_ID>" \
  --key index.html

# Invalidate CloudFront
aws cloudfront create-invalidation \
  --distribution-id E2YNKCD0KTWGSA \
  --paths "/*"
```

### Backend Rollback — Script
```bash
export ASG_NAME="starttech-prod-asg"
export ECR_REGISTRY="757559216958.dkr.ecr.us-east-1.amazonaws.com"
export ECR_REPOSITORY="starttech-backend"

./scripts/rollback.sh <previous-git-sha>
```

### Backend Rollback — Manual
```bash
# List available ECR images sorted by date
aws ecr describe-images \
  --repository-name starttech-backend \
  --query 'sort_by(imageDetails,&imagePushedAt)[*].{Tags:imageTags,Pushed:imagePushedAt}' \
  --output table

# Get Launch Template ID
LT_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names starttech-prod-asg \
  --query 'AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId' \
  --output text)

# List LT versions to find the previous good one
aws ec2 describe-launch-template-versions \
  --launch-template-id "$LT_ID" \
  --query 'LaunchTemplateVersions[*].{Version:VersionNumber,Desc:VersionDescription,Created:CreateTime}' \
  --output table

# Point ASG to a previous LT version
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name starttech-prod-asg \
  --launch-template "LaunchTemplateId=$LT_ID,Version=<PREVIOUS_VERSION>"

# Start rolling update
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name starttech-prod-asg \
  --strategy Rolling \
  --preferences '{"MinHealthyPercentage":50,"InstanceWarmup":60}'
```

### Cancel In-Progress Deploy
```bash
aws autoscaling cancel-instance-refresh \
  --auto-scaling-group-name starttech-prod-asg
```

---

## Scaling

```bash
# Manually set desired capacity
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name starttech-prod-asg \
  --desired-capacity 3

# View current scaling activity
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name starttech-prod-asg \
  --max-items 10 \
  --query 'Activities[*].{Status:StatusCode,Cause:Cause,Start:StartTime}'
```

**Auto Scaling Policy:**
- CPU > 70% for 2 consecutive minutes → scale out +1 instance
- CPU < 20% for 5 consecutive minutes → scale in −1 instance
- Min: 1 · Max: 4 · Default: 2

---

## Logs

```bash
# Tail backend error logs (last 5 minutes)
aws logs filter-log-events \
  --log-group-name /starttech/prod/backend \
  --start-time $(date -d '5 minutes ago' +%s)000 \
  --filter-pattern "ERROR"

# All logs last 10 minutes
aws logs filter-log-events \
  --log-group-name /starttech/prod/backend \
  --start-time $(date -d '10 minutes ago' +%s)000

# Tail live logs (CloudWatch Logs Insights)
# AWS Console → CloudWatch → Log Insights → select /starttech/prod/backend
# Paste queries from: monitoring/log-insights-queries.txt

# Logs from a specific instance (via docker on SSM session)
aws ssm start-session --target <instance-id>
docker logs starttech-backend --tail 200 --follow
```

---

## Infrastructure (Terraform)

```bash
cd starttech-infra

# Plan changes
cd terraform && terraform plan

# Apply changes
terraform apply

# Destroy all resources (costs stop immediately)
terraform destroy
```

### Destroy & Recreate via Pipeline
```bash
# Destroy: GitHub → starttech-infra → Actions → Infrastructure Deploy → Run workflow → destroy
# Recreate: GitHub → starttech-infra → Actions → Infrastructure Deploy → Run workflow → apply
# Note: S3 state bucket is NOT destroyed — managed separately by bootstrap/
```

---

## MongoDB Atlas

EC2 instances egress through NAT Gateway. NAT Gateway EIPs must be in the Atlas IP allowlist.

```bash
# Get NAT Gateway EIPs
aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=starttech-prod-nat-eip-*" \
  --query 'Addresses[*].PublicIp' \
  --output text

# Then add these IPs to:
# MongoDB Atlas → Network Access → IP Access List
```

**Atlas Connection String:**
```
mongodb+srv://starttech-user:<password>@starttech-prod.3w7lwzq.mongodb.net/?appName=starttech-prod
```

**Collections:** `users`, `todos` (in database `much_todo_db`)

---

## Common Issues

| Symptom | Check | Fix |
|---|---|---|
| 502 Bad Gateway from ALB | EC2 health in target group; `docker ps` on instance | Restart container or trigger rolling update |
| `/health` returns `{"database":"down"}` | MongoDB Atlas IP allowlist | Add NAT Gateway EIPs to Atlas Network Access |
| `/health` returns `{"cache":"down"}` | Redis security group; Redis endpoint | Verify backend SG allows 6379 to Redis SG |
| CloudFront serving stale content | CloudFront invalidation | `aws cloudfront create-invalidation --distribution-id E2YNKCD0KTWGSA --paths "/*"` |
| Instance refresh stuck | ASG describe-instance-refreshes | Cancel refresh and investigate; check CloudWatch logs |
| Slow deploys / warmup timeout | Instance takes too long to pass `/health` | Check container logs; verify env vars injected correctly in userdata |
| Frontend build passes but app broken | `VITE_API_BASE_URL` wrong | Verify secret `VITE_API_BASE_URL=http://starttech-prod-alb-573464244.us-east-1.elb.amazonaws.com` |
| CORS errors in browser | `ALLOWED_ORIGINS` mismatch | Verify secret matches CloudFront domain exactly |
| Container not starting | Env var missing (MONGO_URI, JWT_SECRET_KEY, etc.) | Check userdata in Launch Template; check SSM session logs |

---

## SSM Session Manager (No SSH Required)

```bash
# List running instances
aws ec2 describe-instances \
  --filters "Name=tag:aws:autoscaling:groupName,Values=starttech-prod-asg" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].{ID:InstanceId,IP:PrivateIpAddress,AZ:Placement.AvailabilityZone}' \
  --output table

# Open a shell session (no port 22, no bastion required)
aws ssm start-session --target <instance-id>

# Useful commands inside the session:
docker ps                                      # list running containers
docker logs starttech-backend --tail 100       # recent logs
docker inspect starttech-backend              # full container config including env vars
docker stats starttech-backend --no-stream    # CPU/memory usage
cat /var/log/cloud-init-output.log            # userdata bootstrap log
```

---

## Alarms & Monitoring

**CloudWatch Dashboard:** AWS Console → CloudWatch → Dashboards → `StartTech-prod`

| Alarm | Condition | Action |
|---|---|---|
| `starttech-prod-alb-5xx` | > 10 errors/min for 2 periods | SNS email alert |
| `starttech-prod-alb-latency` | p95 > 2s for 3 periods | SNS email alert |
| `starttech-prod-cpu-high` | CPU > 70% for 2 min | Scale out +1 |
| `starttech-prod-cpu-low` | CPU < 20% for 5 min | Scale in -1 |

**SNS Topic:** `arn:aws:sns:us-east-1:757559216958:starttech-prod-alarms`

```bash
# Manually trigger an alarm test
aws cloudwatch set-alarm-state \
  --alarm-name starttech-prod-alb-5xx \
  --state-value ALARM \
  --state-reason "Manual test"
```

---

## API Endpoints

The API is documented via Swagger UI at `/swagger/index.html` on any running EC2 instance (access via SSM port forwarding).

| Method | Path | Auth | Description |
|---|---|---|---|
| GET | `/health` | — | MongoDB + Redis status |
| GET | `/ping` | — | Simple liveness check |
| POST | `/auth/register` | — | Create account |
| POST | `/auth/login` | — | Login (sets httpOnly cookie + returns JWT) |
| POST | `/auth/logout` | — | Clear session cookie |
| GET | `/auth/username-check/:username` | — | Check username availability |
| GET | `/users/me` | ✓ | Get current user |
| PUT | `/users/me` | ✓ | Update profile |
| PUT | `/users/me/password` | ✓ | Change password |
| DELETE | `/users/me` | ✓ | Delete account + all todos (transactional) |
| GET | `/tasks` | ✓ | List user's tasks |
| POST | `/tasks` | ✓ | Create task |
| GET | `/tasks/:id` | ✓ | Get single task |
| PUT | `/tasks/:id` | ✓ | Update task |
| DELETE | `/tasks/:id` | ✓ | Delete task |

**Note:** Frontend routes use `/todos` (client-side). Backend task routes use `/tasks` to avoid conflicts.

---

## Environment Variables (Backend)

Injected via Launch Template userdata at instance boot:

| Variable | Description |
|---|---|
| `PORT` | Server port (default `8080`) |
| `MONGO_URI` | MongoDB Atlas connection string |
| `DB_NAME` | `much_todo_db` |
| `JWT_SECRET_KEY` | HS256 signing secret |
| `JWT_EXPIRATION_HOURS` | Token lifetime (default `72`) |
| `ENABLE_CACHE` | `true` to enable Redis |
| `REDIS_ADDR` | Redis host:port |
| `ALLOWED_ORIGINS` | Comma-separated CORS origins |
| `SECURE_COOKIE` | `false` (HTTP ALB); set `true` if HTTPS terminates at backend |
| `LOG_LEVEL` | `INFO` in production |
| `LOG_FORMAT` | `json` in production |
