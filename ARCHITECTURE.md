# Architecture Documentation

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                          Internet                               │
└──────────┬──────────────────────────────┬───────────────────────┘
           │                              │
           ▼                              ▼
  ┌─────────────────┐            ┌─────────────────┐
  │   CloudFront    │            │      ALB         │
  │   (CDN/HTTPS)   │            │  (port 80/443)   │
  └────────┬────────┘            └────────┬─────────┘
           │                              │
           ▼                              ▼
  ┌─────────────────┐     ┌──────────────────────────────┐
  │    S3 Bucket    │     │     Auto Scaling Group        │
  │  (React SPA)    │     │  ┌────────────┐ ┌──────────┐ │
  │  Private + OAC  │     │  │  EC2 (Go)  │ │ EC2 (Go) │ │
  └─────────────────┘     │  └──────┬─────┘ └────┬─────┘ │
                          └─────────┼─────────────┼───────┘
                                    │             │
                          ┌─────────▼─────────────▼──────┐
                          │      ElastiCache Redis         │
                          │      (private subnets)         │
                          └────────────────────────────────┘
                                    │
                          ┌─────────▼──────────┐
                          │   MongoDB Atlas     │
                          │   (external SaaS)   │
                          └────────────────────┘

Observability:
  EC2 instances → CloudWatch Logs → Log Insights
  EC2 + ALB + Redis → CloudWatch Metrics → Alarms → SNS → Email
  CloudWatch Dashboard (unified view)
```

## Security Design

### Network Isolation
- Frontend S3 bucket has **zero public access** — served exclusively via CloudFront with Origin Access Control
- EC2 instances live in **private subnets** with no public IPs
- Redis is in private subnets, accessible only from the backend security group
- ALB is the only internet-facing compute resource

### IAM Least Privilege
- EC2 instances use an instance role with only:
  - `CloudWatchAgentServerPolicy` — write logs and metrics
  - `AmazonSSMManagedInstanceCore` — SSM Session Manager (no SSH required)
  - Scoped ECR pull permissions (no push, no delete)

### Secrets Management
- All secrets (MONGO_URI, JWT_SECRET, etc.) are stored in **GitHub Actions Secrets**
- Passed to EC2 as environment variables via Launch Template user-data at boot
- Never stored in Terraform state in plaintext — use `sensitive = true`
- For production hardening: migrate to AWS Secrets Manager + `aws secretsmanager get-secret-value` in user-data

### HTTPS Enforcement
- CloudFront: `redirect-to-https` viewer protocol policy
- Backend: Secure cookie flag (`SECURE_COOKIE=true`) — cookies only sent over HTTPS

## CI/CD Flow

```
Developer pushes to main
        │
        ├─► frontend-ci-cd.yml (if Client/** changed)
        │       Lint → Build → S3 sync → CF invalidate → smoke test
        │
        └─► backend-ci-cd.yml (if Server/** changed)
                Test → Docker build → Trivy scan → ECR push
                → ASG instance refresh (rolling, 50% healthy)
                → wait for Successful → ALB health check
```

## Scaling Strategy

| Signal | Action |
|--------|--------|
| CPU > 70% for 2 minutes | Scale up +1 instance |
| CPU < 20% for 5 minutes | Scale down -1 instance |
| Min instances | 1 |
| Max instances | 4 |
| Rolling deploy | 50% min healthy, 60s instance warmup |

## Data Flow

1. **User request** → CloudFront → S3 (static assets cached at edge)
2. **API call** → CloudFront (or direct) → ALB → EC2 (Go API)
3. **Auth**: Go API validates JWT from httpOnly cookie or `Authorization: Bearer` header
4. **Cache check**: Go API checks Redis for username availability / session data
5. **DB query**: Go API reads/writes MongoDB Atlas over TLS
6. **Logging**: Go API writes structured JSON logs → Docker awslogs driver → CloudWatch Logs
