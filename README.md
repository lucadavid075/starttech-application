# MuchToDo — Full-Stack Task Management Application

A production-grade, full-stack task management application built with a **React 19** frontend and a **Go (Gin)** backend, deployed on AWS with automated CI/CD pipelines and infrastructure-as-code.

---

## Architecture Overview

![System Architecture](./architecture.png)

The system is split into two independently deployable layers — a static frontend and a containerised API backend — both living inside a single AWS VPC.

| Layer | Technology |
|---|---|
| **Frontend** | React 19 + TypeScript + Vite, hosted on S3 and served via CloudFront |
| **Backend** | Go (Gin) REST API, Dockerised and deployed on EC2 via Auto Scaling Group |
| **Database** | MongoDB Atlas (external managed SaaS) |
| **Cache** | Amazon ElastiCache (Redis) — username availability & session data |
| **Container Registry** | Amazon ECR |
| **DNS / CDN** | Amazon Route 53 + CloudFront |
| **Infrastructure** | Terraform (VPC, subnets, security groups, IAM, CloudWatch) |
| **CI/CD** | GitHub Actions |
| **Observability** | Amazon CloudWatch (logs, metrics, alarms), AWS CloudTrail, AWS IAM |

### Traffic Flow

```
Users → Route 53 → CloudFront → S3 (React SPA, edge-cached)
                              → ALB → EC2 ASG (Go API, private subnets)
                                          → ElastiCache Redis
                                          → MongoDB Atlas (TLS)
                                          → CloudWatch Logs
```

- The S3 bucket is **fully private** — content is delivered exclusively through CloudFront with Origin Access Control (OAC).  
- EC2 instances have **no public IPs**. Outbound traffic egresses through a NAT Gateway. Inbound traffic is accepted only from the ALB security group.  
- The ALB is the **only internet-facing compute resource**.

---

## Stack

| Concern | Choice |
|---|---|
| Frontend framework | React 19 + TypeScript |
| Bundler | Vite |
| Routing | TanStack Router |
| Server state | TanStack Query |
| Forms | React Hook Form + Zod |
| UI components | shadcn/ui + Radix UI primitives |
| Styling | Tailwind CSS v4 |
| Backend framework | Go — Gin |
| Auth | JWT (httpOnly cookie + `Authorization: Bearer`) |
| Cache client | go-redis v9 |
| MongoDB driver | mongo-driver v1 |
| Config | Viper |
| API docs | Swagger (swaggo) |
| Container base | `scratch` (zero OS, minimal attack surface) |

---

## Repository Structure

```
muchtodo/
├── .github/
│   └── workflows/
│       ├── frontend-ci-cd.yml   # Lint → Build → S3 deploy → CloudFront invalidate
│       └── backend-ci-cd.yml    # Test → Docker build → Trivy scan → ECR push → ASG rolling deploy
│
├── frontend/                    # React SPA (Vite)
│   ├── src/
│   │   ├── components/          # Shared UI components (TodoItem, CreateTodo, shadcn/ui)
│   │   ├── context/             # AuthContext provider
│   │   ├── hooks/               # useAuth
│   │   ├── lib/                 # apiClient (axios), utils
│   │   ├── routes/              # TanStack Router file-based routes
│   │   └── types/               # TypeScript interfaces
│   ├── public/
│   ├── vite.config.ts
│   └── package.json
│
├── backend/
│   └── MuchToDo/                # Go API
│       ├── cmd/api/main.go      # Entry point — wires config, DB, cache, router
│       ├── internal/
│       │   ├── auth/            # JWT token service
│       │   ├── cache/           # Redis cache interface + NoOp fallback
│       │   ├── config/          # Viper config loader
│       │   ├── database/        # MongoDB connection
│       │   ├── handlers/        # HTTP handlers (health, todo, user)
│       │   ├── logger/          # slog structured logger
│       │   ├── middleware/       # Auth middleware, CORS, structured logger
│       │   ├── models/          # Domain models + DTOs
│       │   ├── routes/          # Route registration + Swagger
│       │   └── utils/           # Cookie domain helper
│       ├── docs/                # Auto-generated Swagger spec
│       ├── Dockerfile           # Multi-stage → scratch image
│       ├── docker-compose.yaml  # Local dev: MongoDB (replica set) + Redis
│       └── Makefile
│
├── scripts/
│   ├── deploy-frontend.sh       # Manual S3 deploy + CF invalidation
│   ├── deploy-backend.sh        # Manual Docker build + ASG rolling update
│   ├── health-check.sh          # Poll /health until 200 or timeout
│   └── rollback.sh              # Re-tag a previous image and trigger rolling deploy
│
├── ARCHITECTURE.md              # Detailed architecture and security notes
└── RUNBOOK.md                   # Operations playbook (deploys, rollbacks, logs, scaling)
```

---

## CI/CD Pipelines

Both pipelines are path-scoped — a frontend change never triggers the backend job and vice versa.

### Frontend Pipeline (`.github/workflows/frontend-ci-cd.yml`)

Triggers on pushes to `main` or `develop` that touch `frontend/**`.

```
Push to main
    │
    ▼
[build]  (all branches)
    ├── npm ci
    ├── ESLint
    ├── npm audit (high severity)
    └── vite build → dist/
    │
    ▼
[deploy]  (main only)
    ├── aws s3 sync
    │     ├── *.html  → Cache-Control: no-cache
    │     └── assets/ → Cache-Control: immutable, max-age=31536000
    ├── CloudFront invalidation (waits for completion)
    └── Smoke test — HTTP 200 from CloudFront domain
```

#### Required Secrets

| Secret | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM deploy credentials |
| `AWS_SECRET_ACCESS_KEY` | IAM deploy credentials |
| `FRONTEND_BUCKET_NAME` | S3 bucket name |
| `CLOUDFRONT_DISTRIBUTION_ID` | CloudFront distribution ID |
| `CLOUDFRONT_DOMAIN` | Domain used for the smoke test |
| `VITE_API_BASE_URL` | Backend ALB URL injected at build time |

---

### Backend Pipeline (`.github/workflows/backend-ci-cd.yml`)

Triggers on pushes to `main` or `develop` that touch `backend/**`.

```
Push to main
    │
    ▼
[test]  (all branches)
    ├── go mod tidy (verified)
    ├── go test -race -coverprofile
    ├── go vet
    ├── staticcheck
    └── gosec (security scanner)
    │
    ▼
[build]  (main only)
    ├── ECR login
    ├── docker buildx (multi-stage, GHA cache)
    ├── Trivy scan — blocks on CRITICAL CVEs
    └── docker push :sha + :latest → ECR
    │
    ▼
[deploy]  (main only, requires production environment approval)
    ├── Update Launch Template (new version, deploy-<sha> description)
    ├── start-instance-refresh (Rolling, 50% min healthy, 60s warmup)
    ├── Poll until Successful — auto-rollback on Failed/Cancelled
    └── ALB health check — 10 × HTTP 200 on /health
```

#### Required Secrets

| Secret | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM deploy credentials |
| `AWS_SECRET_ACCESS_KEY` | IAM deploy credentials |
| `ASG_NAME` | Auto Scaling Group name |
| `ALB_DNS_NAME` | ALB DNS name for post-deploy health check |

---

## Security Design

### Network Isolation
- EC2 instances live in **private subnets** with no public IPs; all egress goes through the NAT Gateway.
- Redis (ElastiCache) is accessible only from the backend security group on port 6379.
- The S3 bucket blocks all public access — only CloudFront (via OAC) can read it.

### IAM Least Privilege
EC2 instance role grants only:
- `CloudWatchAgentServerPolicy` — write logs and metrics
- `AmazonSSMManagedInstanceCore` — SSM Session Manager (SSH is not open)
- Scoped ECR pull-only permissions

### Secrets Management
- Application secrets (`MONGO_URI`, `JWT_SECRET_KEY`, Redis credentials) are stored in **GitHub Actions Secrets**.
- They are injected into EC2 as environment variables through the Launch Template user-data at boot time.
- They are **never stored in Terraform state in plaintext** (`sensitive = true`).
- Production hardening path: migrate to **AWS Secrets Manager** with `aws secretsmanager get-secret-value` in user-data.

### HTTPS Enforcement
- CloudFront viewer protocol policy: `redirect-to-https`
- JWT cookies are set with `HttpOnly`, `SameSite`, and `Secure` flags (`SECURE_COOKIE=true` in production)

### Container Security
- The Docker image is built **from scratch** — no shell, no OS, minimal attack surface.
- Non-root user (`nobody`) is enforced in the image.
- Trivy blocks any push containing **CRITICAL** CVEs.

---

## Scaling

| Signal | Action |
|---|---|
| CPU > 70% for 2 min | Scale out +1 instance |
| CPU < 20% for 5 min | Scale in −1 instance |
| Min instances | 1 |
| Max instances | 4 |
| Rolling deploy | 50% min healthy, 60 s instance warmup |

The ASG spans **two Availability Zones** (AZ-A and AZ-B) for fault tolerance.

---

## API Reference

The API is self-documenting via Swagger UI, available at `/swagger/index.html` on a running instance.

### Auth Endpoints

| Method | Path | Description |
|---|---|---|
| `POST` | `/auth/register` | Create a new account |
| `POST` | `/auth/login` | Log in — sets httpOnly cookie + returns JWT in body |
| `POST` | `/auth/logout` | Clear session cookie |
| `GET` | `/auth/username-check/:username` | Check username availability (cache-backed) |

### User Endpoints *(protected)*

| Method | Path | Description |
|---|---|---|
| `GET` | `/users/me` | Get current user profile |
| `PUT` | `/users/me` | Update first name, last name, or username |
| `PUT` | `/users/me/password` | Change password |
| `DELETE` | `/users/me` | Delete account + all associated todos (transactional) |

### Task Endpoints *(protected)*

| Method | Path | Description |
|---|---|---|
| `GET` | `/tasks` | List all tasks for the authenticated user |
| `POST` | `/tasks` | Create a task |
| `GET` | `/tasks/:id` | Get a single task |
| `PUT` | `/tasks/:id` | Update a task (title, description, completed) |
| `DELETE` | `/tasks/:id` | Delete a task |

### Utility

| Method | Path | Description |
|---|---|---|
| `GET` | `/health` | Returns status of MongoDB and Redis |
| `GET` | `/ping` | Simple liveness check |

---

## Local Development

### Prerequisites

- Go 1.22+
- Node.js 20+
- Docker + Docker Compose
- AWS CLI (for manual deploy scripts)

### Backend

```bash
cd backend/MuchToDo

# Start MongoDB (replica set) + Redis + mongo-express + redis-commander
docker-compose up -d

# Copy and fill in environment variables
cp .env.example .env

# Generate Swagger docs and run the server
make run
# → http://localhost:8080
# → Swagger UI: http://localhost:8080/swagger/index.html
# → mongo-express: http://localhost:8081
# → redis-commander: http://localhost:8082
```

Key environment variables (see `.env.example` for full list):

| Variable | Default | Description |
|---|---|---|
| `PORT` | `8080` | Server port |
| `MONGO_URI` | — | MongoDB connection string |
| `DB_NAME` | `much_todo_db` | Database name |
| `JWT_SECRET_KEY` | — | HS256 signing secret |
| `JWT_EXPIRATION_HOURS` | `72` | Token lifetime |
| `ENABLE_CACHE` | `false` | Enable Redis caching |
| `REDIS_ADDR` | — | `host:port` of Redis |
| `ALLOWED_ORIGINS` | `http://localhost:5173` | CORS allowed origins (comma-separated) |
| `SECURE_COOKIE` | `false` | Set Secure flag on JWT cookie |
| `LOG_LEVEL` | `DEBUG` | `DEBUG` / `INFO` / `WARN` / `ERROR` |
| `LOG_FORMAT` | `json` | `json` or `text` |

### Frontend

```bash
cd frontend

# Copy and fill in environment variables
cp .env.example .env        # Set VITE_API_BASE_URL=http://localhost:8080

npm install
npm run dev
# → http://localhost:5173
```

### Running Tests

```bash
# Backend — unit tests
cd backend/MuchToDo
go test -v -race ./...

# Backend — integration tests (spins up real MongoDB + Redis via Testcontainers)
INTEGRATION=true go test -tags=integration -v ./...

# Frontend — lint
cd frontend
npm run lint
```

---

## Manual Deploy Scripts

These scripts replicate what the CI/CD pipelines do and are useful for hotfixes or environments without GitHub Actions.

```bash
# Deploy frontend
export FRONTEND_BUCKET_NAME="muchtodo-frontend-prod"
export CLOUDFRONT_DISTRIBUTION_ID="E1XXXXXXXXXXXXX"
export VITE_API_BASE_URL="http://your-alb.us-east-1.elb.amazonaws.com"
./scripts/deploy-frontend.sh

# Deploy backend
export ECR_REGISTRY="123456789012.dkr.ecr.us-east-1.amazonaws.com"
export ECR_REPOSITORY="muchtodo-backend"
export ASG_NAME="muchtodo-prod-asg"
./scripts/deploy-backend.sh

# Poll /health until it returns 200
./scripts/health-check.sh http://your-alb.us-east-1.elb.amazonaws.com

# Roll back backend to a previous Git SHA image
./scripts/rollback.sh <previous-git-sha>
```

---

## Infrastructure (Terraform)

Terraform provisions and manages:

- VPC, public and private subnets across two AZs
- Internet Gateway, NAT Gateway, route tables
- Security groups (ALB, EC2, Redis)
- IAM roles and instance profiles
- EC2 Launch Template and Auto Scaling Group
- CloudWatch Log Groups, metric alarms, and dashboards
- Amazon ElastiCache (Redis) cluster

> **MongoDB** is a managed external SaaS (MongoDB Atlas). Add the NAT Gateway EIPs to your Atlas IP allowlist so the EC2 instances can reach it.

---

## Observability

| Signal | Source | Destination |
|---|---|---|
| Structured JSON logs | Go API → Docker `awslogs` driver | CloudWatch Logs `/muchtodo/prod/backend` |
| EC2 metrics (CPU, mem, disk) | CloudWatch Agent | CloudWatch Metrics |
| ALB metrics | ALB | CloudWatch Metrics |
| Redis metrics | ElastiCache | CloudWatch Metrics |
| Alarms → notifications | CloudWatch Alarms | SNS → Email |
| API call audit trail | All AWS API calls | CloudTrail |
| Access management | IAM roles & policies | AWS IAM |

Log Insights queries are maintained in `monitoring/log-insights-queries.txt`.

---

## Common Operations

See [`RUNBOOK.md`](./RUNBOOK.md) for the full operations playbook. Quick reference:

```bash
# Tail backend error logs (last 5 minutes)
aws logs filter-log-events \
  --log-group-name /muchtodo/prod/backend \
  --start-time $(date -d '5 minutes ago' +%s000) \
  --filter-pattern "ERROR"

# SSH-free shell on an EC2 instance via SSM
aws ssm start-session --target <instance-id>

# Manually scale the ASG
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name muchtodo-prod-asg \
  --desired-capacity 3

# Cancel an in-progress rolling deploy
aws autoscaling cancel-instance-refresh \
  --auto-scaling-group-name muchtodo-prod-asg
```
