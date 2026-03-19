#!/usr/bin/env bash
# =============================================================================
# deploy-stack.sh — Deploy all 3 ecommerce-infra CloudFormation stacks
#
# Usage:  ./deploy-stack.sh [env-name] [aws-region]
# Example: ./deploy-stack.sh ecommerce-demo ap-southeast-2
#
# Stacks deployed (in order):
#   1. {env}-networking  → VPC, subnets, SGs, IAM roles
#   2. {env}-data        → ECR, RDS PostgreSQL, ElastiCache, Secrets Manager
#   3. {env}-compute     → ECS cluster, ALBs, Task Definitions, ECS services
#
# Prerequisites:
#   - AWS CLI v2 installed and configured (aws configure)
#   - Sufficient IAM permissions (CloudFormation, ECR, RDS, ECS, EC2, IAM, etc.)
# =============================================================================
set -euo pipefail

ENV_NAME="${1:-ecommerce-demo}"
AWS_REGION="${2:-ap-southeast-2}"
TEMPLATES_DIR="$(cd "$(dirname "$0")/../templates" && pwd)"

NETWORKING_STACK="${ENV_NAME}-networking"
DATA_STACK="${ENV_NAME}-data"
COMPUTE_STACK="${ENV_NAME}-compute"

# ── Colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
step() { echo -e "\n${YELLOW}==> $*${NC}"; }
ok()   { echo -e "${GREEN}✓  $*${NC}"; }

# ── Helper: get a single CloudFormation stack output value ───────────────────
get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$2" \
    --region "$AWS_REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text 2>/dev/null || echo "N/A"
}

# ── Validation ────────────────────────────────────────────────────────────────
if ! command -v aws &>/dev/null; then
  echo "ERROR: AWS CLI v2 not found. Install from https://aws.amazon.com/cli/"; exit 1
fi
if [ ! -d "$TEMPLATES_DIR" ]; then
  echo "ERROR: templates directory not found at $TEMPLATES_DIR"; exit 1
fi

echo -e "\n${CYAN}=================================================${NC}"
echo -e "${CYAN}  ecommerce-infra Stack Deployment${NC}"
echo -e "${CYAN}=================================================${NC}"
echo "  Environment : $ENV_NAME"
echo "  Region      : $AWS_REGION"
echo "  Started at  : $(date)"
echo ""

# ── Stack 1: Networking ───────────────────────────────────────────────────────
step "[1/3] Deploying networking stack: $NETWORKING_STACK"
echo "      Creates: VPC, subnets, IGW, route tables, security groups, IAM roles"
aws cloudformation deploy \
  --stack-name         "$NETWORKING_STACK" \
  --template-file      "$TEMPLATES_DIR/01-networking.yaml" \
  --parameter-overrides EnvironmentName="$ENV_NAME" \
  --capabilities       CAPABILITY_NAMED_IAM \
  --region             "$AWS_REGION" \
  --tags               Environment="$ENV_NAME" ManagedBy=ecommerce-infra \
  --no-fail-on-empty-changeset
ok "Networking stack ready"

# ── Stack 2: Data ─────────────────────────────────────────────────────────────
step "[2/3] Deploying data stack: $DATA_STACK"
echo "      Creates: ECR repos, RDS PostgreSQL, ElastiCache Redis, Secrets Manager"
echo "      ⏳ RDS instance provisioning takes 5-10 minutes — please wait..."
aws cloudformation deploy \
  --stack-name         "$DATA_STACK" \
  --template-file      "$TEMPLATES_DIR/02-data.yaml" \
  --parameter-overrides EnvironmentName="$ENV_NAME" \
  --capabilities       CAPABILITY_NAMED_IAM \
  --region             "$AWS_REGION" \
  --tags               Environment="$ENV_NAME" ManagedBy=ecommerce-infra \
  --no-fail-on-empty-changeset
ok "Data stack ready"

# ── Stack 3: Compute ──────────────────────────────────────────────────────────
step "[3/3] Deploying compute stack: $COMPUTE_STACK"
echo "      Creates: ECS cluster, ALBs, target groups, task definitions, ECS services"
aws cloudformation deploy \
  --stack-name         "$COMPUTE_STACK" \
  --template-file      "$TEMPLATES_DIR/03-compute.yaml" \
  --parameter-overrides EnvironmentName="$ENV_NAME" \
  --capabilities       CAPABILITY_NAMED_IAM \
  --region             "$AWS_REGION" \
  --tags               Environment="$ENV_NAME" ManagedBy=ecommerce-infra \
  --no-fail-on-empty-changeset
ok "Compute stack ready"

# ── Print key outputs ─────────────────────────────────────────────────────────
FRONTEND_URL=$(get_output "FrontendALBUrl"  "$COMPUTE_STACK")
BACKEND_URL=$(get_output  "BackendALBUrl"   "$COMPUTE_STACK")
BACKEND_ECR=$(get_output  "BackendECRRepositoryUri"  "$COMPUTE_STACK")
FRONTEND_ECR=$(get_output "FrontendECRRepositoryUri" "$COMPUTE_STACK")
ECS_CLUSTER=$(get_output  "ECSClusterName" "$COMPUTE_STACK")

echo ""
echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}  All stacks deployed successfully!${NC}"
echo -e "${GREEN}=================================================${NC}"
echo ""
echo "  Endpoints (available after first CI deploy):"
echo "    Frontend URL  : $FRONTEND_URL"
echo "    Backend URL   : $BACKEND_URL"
echo "    Swagger UI    : ${BACKEND_URL}/swagger-ui.html"
echo ""
echo "  ECR Repositories:"
echo "    Backend ECR   : $BACKEND_ECR"
echo "    Frontend ECR  : $FRONTEND_ECR"
echo ""
echo "  ECS:"
echo "    Cluster       : $ECS_CLUSTER"
echo "    Backend svc   : ${ENV_NAME}-backend-service  (DesiredCount=0 until CI deploys)"
echo "    Frontend svc  : ${ENV_NAME}-frontend-service (DesiredCount=0 until CI deploys)"
echo ""
echo "  Next steps:"
echo "    1. Set GitHub variable  STACK_NAME=$ENV_NAME  in both repos"
echo "    2. Trigger GitHub Actions (push to main, or use workflow_dispatch)"
echo "    3. After CI completes, your demo will be live at: $FRONTEND_URL"
echo ""
echo "  To tear down all resources after the demo:"
echo "    ./teardown-stack.sh $ENV_NAME $AWS_REGION"
echo ""
echo "  Completed at: $(date)"
