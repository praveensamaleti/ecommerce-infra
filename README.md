# ecommerce-infra

Infrastructure-as-Code for the ecommerce platform using **AWS CloudFormation**.
Designed for a **demo-friendly workflow**: spin everything up 2 hours before a demo,
test end-to-end, then tear it all down to preserve free-tier hours.

---

## Architecture Overview

```
Internet
   │
   ▼
[ ALB: frontend-alb ]          [ ALB: backend-alb ]
   │  port 80                      │  port 80 → 8080
   ▼                               ▼
[ ECS Fargate ]              [ ECS Fargate ]
  react-ecommerce               ecommerce-backend
  (Nginx, port 80)              (Spring Boot, port 8080)
                                    │            │
                              ┌─────┘            └─────┐
                              ▼                        ▼
                        [ RDS PostgreSQL ]    [ ElastiCache Redis ]
                          db.t3.micro           cache.t2.micro
                          (private subnet)      (private subnet)

All secrets injected at runtime via AWS Secrets Manager (no hardcoded values).
```

### Subnet Layout (no NAT Gateway = zero NAT cost)
| Subnet         | CIDR         | AZ  | Purpose                         |
|----------------|--------------|-----|---------------------------------|
| public-1       | 10.0.1.0/24  | AZ1 | ECS Fargate + ALB               |
| public-2       | 10.0.2.0/24  | AZ2 | ECS Fargate + ALB (multi-AZ)    |
| private-1      | 10.0.3.0/24  | AZ1 | RDS + ElastiCache               |
| private-2      | 10.0.4.0/24  | AZ2 | RDS subnet group (multi-AZ req) |

ECS tasks run in **public subnets** with `AssignPublicIp: ENABLED` — this lets them
reach ECR and Secrets Manager without a NAT Gateway (saves ~$32/month).

---

## Cost Estimate (per 2-hour demo session)

| Service              | Free Tier?                    | 2-hr cost  |
|----------------------|-------------------------------|------------|
| RDS db.t3.micro      | ✅ 750 hrs/month (12 months)  | ~$0.00     |
| ElastiCache t2.micro | ✅ 750 hrs/month (12 months)  | ~$0.00     |
| ECR storage          | ✅ 500 MB/month (12 months)   | ~$0.00     |
| Fargate – backend    | ❌ Pay-per-use (0.5vCPU/1GB)  | ~$0.025    |
| Fargate – frontend   | ❌ Pay-per-use (0.25vCPU/512) | ~$0.012    |
| ALB × 2              | ❌ $0.008/hr each             | ~$0.032    |
| Secrets Manager × 3  | $0.40/secret/month            | ~$0.001    |
| **Total**            |                               | **~$0.07** |

> **Tip:** Fargate and ALB are the only non-free-tier services. At $0.07/demo session
> you can run 400+ demos before spending $30. Always run `teardown-stack.sh` after demos.

---

## Folder Structure

```
ecommerce-infra/
├── README.md                     ← this file
├── templates/
│   ├── 01-networking.yaml        ← VPC, subnets, SGs, IAM roles       [Chunk 1]
│   ├── 02-data.yaml              ← ECR, RDS, ElastiCache, Secrets Mgr  [Chunk 2]
│   └── 03-compute.yaml           ← ECS, ALB, task defs, services        [Chunk 3]
└── scripts/
    ├── deploy-stack.sh           ← Deploy all 3 stacks in order         [Chunk 4]
    ├── teardown-stack.sh         ← Delete all 3 stacks in reverse        [Chunk 4]
    └── pre-demo.sh               ← Full pre-demo: deploy + trigger CI    [Chunk 4]
```

GitHub Actions workflows (updated in Chunk 4):
- `ecommerce-backend/.github/workflows/deploy.yml`
- `react-ecommerce-app/.github/workflows/deploy.yml`
- `react-ecommerce-app/Dockerfile` (build-arg for dynamic API URL)

---

## Prerequisites

1. **AWS CLI v2** installed and configured (`aws configure`)
2. **GitHub Secrets** set in both repos:
   - `AWS_ACCESS_KEY_ID`
   - `AWS_SECRET_ACCESS_KEY`
   - `STACK_NAME` — the `EnvironmentName` you use for the stack (e.g. `ecommerce-demo`)
   - `AWS_REGION` — e.g. `ap-southeast-2`
3. **jq** installed (used by scripts to parse CloudFormation outputs)

---

## Stack Parameters

All three templates share one key parameter:

| Parameter           | Default          | Description                              |
|---------------------|------------------|------------------------------------------|
| `EnvironmentName`   | `ecommerce-demo` | Prefix for every AWS resource name       |
| `DBMasterPassword`  | (auto-generated) | Set in 02-data stack, stored in Secrets Manager |

Change `EnvironmentName` between deployments to keep resource names unique.
Example: `ecommerce-demo`, `ecommerce-v2`, `ecommerce-apr15`.

---

## Quick Start (pre-demo workflow)

```bash
# 1. Deploy all infrastructure (run 2 hours before demo)
cd ecommerce-infra
./scripts/deploy-stack.sh ecommerce-demo ap-southeast-2

# 2. Trigger CI/CD pipelines (push a commit or manually dispatch)
#    The workflows now auto-read ALB DNS from CloudFormation outputs.
#    Backend and frontend images are built + deployed automatically.

# 3. Verify
aws cloudformation describe-stacks \
  --stack-name ecommerce-demo-compute \
  --query 'Stacks[0].Outputs'

# 4. After demo — tear everything down
./scripts/teardown-stack.sh ecommerce-demo ap-southeast-2
```

---

## Security Group Rules Summary

| Security Group         | Inbound                              | Outbound     |
|------------------------|--------------------------------------|--------------|
| `alb-sg`               | TCP 80, 443 from `0.0.0.0/0`         | All          |
| `backend-ecs-sg`       | TCP 8080 from `alb-sg`               | All          |
| `frontend-ecs-sg`      | TCP 80 from `alb-sg`                 | All          |
| `rds-sg`               | TCP 5432 from `backend-ecs-sg`       | All (AWS default) |
| `cache-sg`             | TCP 6379 from `backend-ecs-sg`       | All (AWS default) |

---

## Secrets (auto-generated, never hardcoded)

Stored in **AWS Secrets Manager**, injected into ECS task definitions at runtime:

| Secret Path                        | Keys                                          |
|------------------------------------|-----------------------------------------------|
| `{EnvironmentName}/rds`            | `username`, `password`, `host`, `port`, `dbname` |
| `{EnvironmentName}/jwt`            | `secret`                                      |

The `REDIS_HOST` is sourced from the ElastiCache stack output (plain text, no auth required
since Redis is inside the VPC behind a security group).

---

## Stack Outputs

Key outputs from the compute stack (03-compute.yaml):

| Output                  | Description                                    |
|-------------------------|------------------------------------------------|
| `BackendALBDNS`         | Backend ALB DNS — used as `REACT_APP_API_URL`  |
| `FrontendALBDNS`        | Frontend ALB DNS — share this URL for demos    |
| `ECSClusterName`        | ECS cluster name                               |
| `BackendECRUri`         | Full ECR URI for backend image pushes          |
| `FrontendECRUri`        | Full ECR URI for frontend image pushes         |
| `BackendServiceName`    | ECS service name (for force-deploy)            |
| `FrontendServiceName`   | ECS service name (for force-deploy)            |
