#!/usr/bin/env bash
# =============================================================================
# teardown-stack.sh — Delete all 3 ecommerce-infra CloudFormation stacks
#
# Usage:   ./teardown-stack.sh [env-name] [aws-region]
# Example: ./teardown-stack.sh ecommerce-demo ap-southeast-2
#
# Stacks deleted (in reverse order):
#   1. {env}-compute     (ECS services, ALBs, task definitions)
#   2. {env}-data        (ECR images, RDS DB, ElastiCache, Secrets Manager)
#   3. {env}-networking  (VPC, subnets, security groups, IAM roles)
#
# What happens to data:
#   - RDS: deleted with SkipFinalSnapshot=true (NO backup — demo data is lost)
#   - ECR: images deleted (EmptyOnDelete=true on the repository)
#   - Secrets Manager: force-deleted immediately (no 30-day recovery window)
#     so you can re-deploy with the same EnvironmentName without name conflicts.
#   - CloudWatch Logs: deleted with the networking stack
# =============================================================================
set -euo pipefail

ENV_NAME="${1:-ecommerce-demo}"
AWS_REGION="${2:-ap-southeast-2}"

NETWORKING_STACK="${ENV_NAME}-networking"
DATA_STACK="${ENV_NAME}-data"
COMPUTE_STACK="${ENV_NAME}-compute"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
step() { echo -e "\n${YELLOW}==> $*${NC}"; }
ok()   { echo -e "${GREEN}✓  $*${NC}"; }

# ── Confirmation ──────────────────────────────────────────────────────────────
echo -e "\n${RED}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║           ⚠  STACK TEARDOWN WARNING  ⚠           ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "  This will PERMANENTLY DELETE all resources in:"
echo -e "    ${YELLOW}$COMPUTE_STACK${NC}    (ECS services, ALBs, task definitions)"
echo -e "    ${YELLOW}$DATA_STACK${NC}       (ECR repos+images, RDS DB, ElastiCache, Secrets)"
echo -e "    ${YELLOW}$NETWORKING_STACK${NC} (VPC, subnets, security groups, IAM roles)"
echo ""
echo -e "  ${RED}All RDS data will be lost permanently (no final snapshot).${NC}"
echo ""
read -rp "  Type the environment name '$ENV_NAME' to confirm teardown: " CONFIRM
echo ""

if [ "$CONFIRM" != "$ENV_NAME" ]; then
  echo "  Input did not match. Teardown aborted — no changes made."
  exit 1
fi

echo -e "${CYAN}=================================================${NC}"
echo -e "${CYAN}  Starting teardown for: $ENV_NAME${NC}"
echo -e "${CYAN}=================================================${NC}"
echo "  Region     : $AWS_REGION"
echo "  Started at : $(date)"

# ── Pre-teardown: scale ECS services to 0 ────────────────────────────────────
# Scaling to 0 before deleting lets running tasks drain gracefully and avoids
# CloudFormation timing out while waiting for tasks to stop.
step "Pre-teardown: scaling ECS services down to 0"
ECS_CLUSTER="${ENV_NAME}-cluster"

for SVC in "${ENV_NAME}-backend-service" "${ENV_NAME}-frontend-service"; do
  aws ecs update-service \
    --cluster  "$ECS_CLUSTER" \
    --service  "$SVC" \
    --desired-count 0 \
    --region   "$AWS_REGION" 2>/dev/null \
    && echo "  Scaled to 0: $SVC" \
    || echo "  Not found (skipped): $SVC"
done

echo "  Waiting 30s for running tasks to stop..."
sleep 30

# ── Step 1: Delete compute stack ─────────────────────────────────────────────
step "[1/3] Deleting compute stack: $COMPUTE_STACK"
if aws cloudformation describe-stacks --stack-name "$COMPUTE_STACK" --region "$AWS_REGION" &>/dev/null; then
  aws cloudformation delete-stack --stack-name "$COMPUTE_STACK" --region "$AWS_REGION"
  echo "  Waiting for compute stack deletion..."
  aws cloudformation wait stack-delete-complete \
    --stack-name "$COMPUTE_STACK" --region "$AWS_REGION"
  ok "Compute stack deleted"
else
  echo "  Stack not found — skipped"
fi

# ── Step 2: Delete data stack ─────────────────────────────────────────────────
step "[2/3] Deleting data stack: $DATA_STACK"
echo "      ⏳ RDS deletion takes 3-8 minutes — please wait..."
if aws cloudformation describe-stacks --stack-name "$DATA_STACK" --region "$AWS_REGION" &>/dev/null; then
  aws cloudformation delete-stack --stack-name "$DATA_STACK" --region "$AWS_REGION"
  echo "  Waiting for data stack deletion (RDS + ElastiCache take several minutes)..."
  aws cloudformation wait stack-delete-complete \
    --stack-name "$DATA_STACK" --region "$AWS_REGION"
  ok "Data stack deleted"
else
  echo "  Stack not found — skipped"
fi

# ── Force-delete Secrets Manager secrets ─────────────────────────────────────
# CloudFormation schedules secret deletion with a 30-day recovery window by default.
# Force-deleting immediately means you can re-deploy with the same EnvironmentName
# right away without hitting "secret already exists" errors.
step "Force-deleting Secrets Manager secrets (bypass 30-day recovery window)"
for SECRET in "${ENV_NAME}/rds" "${ENV_NAME}/jwt"; do
  aws secretsmanager delete-secret \
    --secret-id                  "$SECRET" \
    --force-delete-without-recovery \
    --region                     "$AWS_REGION" 2>/dev/null \
    && echo "  Force-deleted: $SECRET" \
    || echo "  Already gone:  $SECRET"
done
ok "Secrets deleted immediately"

# ── Step 3: Delete networking stack ──────────────────────────────────────────
step "[3/3] Deleting networking stack: $NETWORKING_STACK"
if aws cloudformation describe-stacks --stack-name "$NETWORKING_STACK" --region "$AWS_REGION" &>/dev/null; then
  aws cloudformation delete-stack --stack-name "$NETWORKING_STACK" --region "$AWS_REGION"
  echo "  Waiting for networking stack deletion..."
  aws cloudformation wait stack-delete-complete \
    --stack-name "$NETWORKING_STACK" --region "$AWS_REGION"
  ok "Networking stack deleted"
else
  echo "  Stack not found — skipped"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}  Teardown complete!${NC}"
echo -e "${GREEN}=================================================${NC}"
echo ""
echo "  All stacks and their resources have been deleted."
echo "  Free-tier hours are preserved."
echo ""
echo "  To redeploy for the next demo:"
echo "    ./deploy-stack.sh $ENV_NAME $AWS_REGION"
echo ""
echo "  Completed at: $(date)"
