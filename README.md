# StartTech Application

Full-stack application — React frontend + Go backend — with complete CI/CD pipelines.

## Stack

| Layer | Tech |
|-------|------|
| Frontend | React 19 + TypeScript + Vite + TanStack Router |
| Backend | Go (Gin) REST API |
| Database | MongoDB Atlas |
| Cache | Redis (AWS ElastiCache) |
| Frontend hosting | AWS S3 + CloudFront |
| Backend hosting | AWS EC2 Auto Scaling Group behind ALB |
| Container registry | AWS ECR |

## Repository Structure

```
starttech-application/
├── .github/workflows/
│   ├── frontend-ci-cd.yml    # Lint → Build → S3 deploy → CF invalidate
│   └── backend-ci-cd.yml     # Test → Docker build → ECR push → ASG rolling deploy
├── Client/                   # React SPA (Vite)
├── Server/MuchToDo/          # Go API
├── backend/
│   └── Dockerfile            # Multi-stage scratch-based image
└── scripts/
    ├── deploy-frontend.sh    # Local frontend deploy
    ├── deploy-backend.sh     # Local backend build + deploy
    ├── health-check.sh       # Poll /health endpoint
    └── rollback.sh           # Rollback to previous image tag
```

## Frontend CI/CD

**Workflow**: `.github/workflows/frontend-ci-cd.yml`

```
Push to main (Client/**)
     │
     ▼
  [build]
  ├── npm ci
  ├── eslint
  ├── npm audit (high severity)
  └── vite build → dist/
     │
     ▼
  [deploy]  (main branch only)
  ├── aws s3 sync (HTML: no-cache, assets: immutable)
  ├── CloudFront invalidation (wait for completion)
  └── Smoke test (HTTP 200 from CloudFront)
```

### Required Secrets (Frontend)

| Secret | Description |
|--------|-------------|
| `AWS_ACCESS_KEY_ID` | IAM credentials |
| `AWS_SECRET_ACCESS_KEY` | IAM credentials |
| `FRONTEND_BUCKET_NAME` | S3 bucket name |
| `CLOUDFRONT_DISTRIBUTION_ID` | CF distribution ID |
| `CLOUDFRONT_DOMAIN` | CF domain for smoke test |
| `VITE_API_BASE_URL` | Backend ALB URL |

## Backend CI/CD

**Workflow**: `.github/workflows/backend-ci-cd.yml`

```
Push to main (Server/**)
     │
     ▼
  [test]
  ├── go mod verify
  ├── go test -race -coverprofile
  ├── go vet
  ├── staticcheck
  └── gosec
     │
     ▼
  [build]  (main branch only)
  ├── ECR login
  ├── docker buildx build (multi-stage)
  ├── Trivy scan (CRITICAL vulns block push)
  └── docker push :sha + :latest
     │
     ▼
  [deploy]
  ├── start-instance-refresh (Rolling, 50% min healthy)
  ├── poll until Successful / Failed
  ├── rollback-instance-refresh on failure
  └── ALB health check
```

### Required Secrets (Backend)

| Secret | Description |
|--------|-------------|
| `AWS_ACCESS_KEY_ID` | IAM credentials |
| `AWS_SECRET_ACCESS_KEY` | IAM credentials |
| `ECR_REPOSITORY_URL` | Full ECR image URI |
| `ASG_NAME` | Auto Scaling Group name |
| `ALB_DNS_NAME` | ALB DNS for health check |
| `SLACK_WEBHOOK_URL` | (optional) failure alerts |

## Local Development

### Frontend

```bash
cd Client
cp .env.example .env        # set VITE_API_BASE_URL
npm install
npm run dev                 # http://localhost:5173
```

### Backend

```bash
cd Server/MuchToDo
cp .env.example .env        # fill in MONGO_URI, JWT_SECRET_KEY, etc.
docker-compose up -d        # starts MongoDB + Redis locally
make run                    # http://localhost:8080
```

### Docker (backend only)

```bash
cd Server/MuchToDo
docker build -f ../../backend/Dockerfile -t starttech-backend .
docker run -p 8080:8080 \
  -e MONGO_URI="..." \
  -e JWT_SECRET_KEY="..." \
  starttech-backend
```

## Scripts

| Script | Usage |
|--------|-------|
| `deploy-frontend.sh` | `FRONTEND_BUCKET_NAME=… CLOUDFRONT_DISTRIBUTION_ID=… ./scripts/deploy-frontend.sh` |
| `deploy-backend.sh` | `ECR_REGISTRY=… ASG_NAME=… ./scripts/deploy-backend.sh` |
| `health-check.sh` | `./scripts/health-check.sh http://your-alb-dns` |
| `rollback.sh` | `ASG_NAME=… ./scripts/rollback.sh <git-sha>` |
