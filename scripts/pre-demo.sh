#!/usr/bin/env bash
# =============================================================================
# pre-demo.sh — End-to-end demo preparation automation
#
# Run this ~30 minutes before your demo. It will:
#   1. Deploy all 3 CloudFormation stacks (infra)
#   2. Optionally set the STACK_NAME GitHub variable in both repos
#   3. Optionally trigger GitHub Actions CI/CD workflows
#   4. Print the live demo URLs
#
# Usage:
#   ./pre-demo.sh [env-name] [aws-region] [backend-repo] [frontend-repo]
#
# Examples:
#   # Deploy infra only (trigger CI manually afterward):
#   ./pre-demo.sh ecommerce-demo ap-southeast-2
#
#   # Full automation (requires gh CLI + auth):
#   ./pre-demo.sh ecommerce-demo ap-southeast-2 \
#     myorg/ecommerce-backend myorg/react-ecommerce-app
#
# Prerequisites:
#   - AWS CLI v2  : installed and configured (aws configure)
#   - jq          : installed (brew install jq / apt install jq)
#   - gh CLI      : optional, for automated CI trigger (gh auth login)
# =============================================================================
set -euo pipefail

ENV_NAME="${1:-ecommerce-demo}"
AWS_REGION="${2:-ap-southeast-2}"
BACKEND_REPO="${3:-}"
FRONTEND_REPO="${4:-}"

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
header() { echo -e "\n${CYAN}══════════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}══════════════════════════════════════════${NC}"; }
step()   { echo -e "${YELLOW}---> $*${NC}"; }
ok()     { echo -e "${GREEN}✓  $*${NC}"; }
warn()   { echo -e "${YELLOW}⚠  $*${NC}"; }

# ── Helper: fetch a CloudFormation stack output value ────────────────────────
get_cf_output() {
  local key="$1" stack="$2"
  aws cloudformation describe-stacks \
    --stack-name "$stack" \
    --region "$AWS_REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$key'].OutputValue" \
    --output text 2>/dev/null || echo "N/A"
}

# ── Validation ────────────────────────────────────────────────────────────────
if ! command -v aws &>/dev/null; then
  echo -e "${RED}ERROR: AWS CLI v2 not found.${NC} Install: https://aws.amazon.com/cli/"; exit 1
fi
if ! command -v jq &>/dev/null; then
  echo -e "${RED}ERROR: jq not found.${NC} Install: brew install jq  OR  apt-get install jq"; exit 1
fi

header "ecommerce-infra Pre-Demo Setup"
echo "  Environment   : $ENV_NAME"
echo "  Region        : $AWS_REGION"
echo "  Backend repo  : ${BACKEND_REPO:-'(not specified — CI must be triggered manually)'}"
echo "  Frontend repo : ${FRONTEND_REPO:-'(not specified — CI must be triggered manually)'}"
echo "  Started at    : $(date)"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1 — Deploy CloudFormation stacks
# ═══════════════════════════════════════════════════════════════════════════════
header "STEP 1/3 — Deploying CloudFormation Stacks"
echo "  Estimated time: 10-15 minutes total."
echo "  (Tip: RDS provisioning is the longest step at 5-10 minutes)"
echo ""

"$SCRIPTS_DIR/deploy-stack.sh" "$ENV_NAME" "$AWS_REGION"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2 — Capture stack outputs
# ═══════════════════════════════════════════════════════════════════════════════
header "STEP 2/3 — Reading Stack Outputs"

COMPUTE_STACK="${ENV_NAME}-compute"

FRONTEND_URL=$(get_cf_output "FrontendALBUrl"            "$COMPUTE_STACK")
BACKEND_URL=$(get_cf_output  "BackendALBUrl"             "$COMPUTE_STACK")
BACKEND_DNS=$(get_cf_output  "BackendALBDNS"             "$COMPUTE_STACK")
ECS_CLUSTER=$(get_cf_output  "ECSClusterName"            "$COMPUTE_STACK")
BACKEND_SVC=$(get_cf_output  "BackendServiceName"        "$COMPUTE_STACK")
FRONTEND_SVC=$(get_cf_output "FrontendServiceName"       "$COMPUTE_STACK")
BACKEND_ECR=$(get_cf_output  "BackendECRRepositoryUri"   "$COMPUTE_STACK")
FRONTEND_ECR=$(get_cf_output "FrontendECRRepositoryUri"  "$COMPUTE_STACK")

echo "  Frontend URL    : $FRONTEND_URL"
echo "  Backend URL     : $BACKEND_URL"
echo "  Backend ALB DNS : $BACKEND_DNS"
echo "  ECS Cluster     : $ECS_CLUSTER"
echo "  Backend service : $BACKEND_SVC"
echo "  Frontend service: $FRONTEND_SVC"
echo "  Backend ECR     : $BACKEND_ECR"
echo "  Frontend ECR    : $FRONTEND_ECR"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3 — Trigger CI/CD pipelines
# ═══════════════════════════════════════════════════════════════════════════════
header "STEP 3/3 — Triggering GitHub Actions CI/CD"

if ! command -v gh &>/dev/null; then
  # ── gh CLI not available: print manual instructions ────────────────────────
  warn "gh CLI not installed — automated CI trigger skipped."
  echo ""
  echo "  ACTION REQUIRED — follow these steps before your demo:"
  echo ""
  echo "  ① Set the STACK_NAME variable in BOTH GitHub repos:"
  echo "       Name  : STACK_NAME"
  echo "       Value : $ENV_NAME"
  echo ""
  if [ -n "$BACKEND_REPO" ]; then
    echo "     Backend:  https://github.com/${BACKEND_REPO}/settings/variables/actions"
  fi
  if [ -n "$FRONTEND_REPO" ]; then
    echo "     Frontend: https://github.com/${FRONTEND_REPO}/settings/variables/actions"
  fi
  echo ""
  echo "  ② Trigger the 'deploy' workflow in each repo (push to main, or"
  echo "     Actions → Build and Deploy to AWS ECS → Run workflow → stack_name=$ENV_NAME)"
  echo ""
  if [ -n "$BACKEND_REPO" ]; then
    echo "     Backend Actions:  https://github.com/${BACKEND_REPO}/actions"
  fi
  if [ -n "$FRONTEND_REPO" ]; then
    echo "     Frontend Actions: https://github.com/${FRONTEND_REPO}/actions"
  fi
  echo ""
  echo "  ③ Wait for both workflows to succeed (~8-10 min total)."

else
  # ── gh CLI available: automate variable setting and workflow dispatch ───────
  for REPO_ENTRY in "backend:$BACKEND_REPO" "frontend:$FRONTEND_REPO"; do
    ROLE="${REPO_ENTRY%%:*}"
    REPO="${REPO_ENTRY##*:}"
    [ -z "$REPO" ] && continue

    echo ""
    step "[$ROLE] Setting STACK_NAME=$ENV_NAME in $REPO"
    gh variable set STACK_NAME \
      --body  "$ENV_NAME" \
      --repo  "$REPO" \
      && ok "Variable set" \
      || warn "Could not set variable — set STACK_NAME=$ENV_NAME manually in $REPO"

    step "[$ROLE] Triggering deploy workflow in $REPO"
    gh workflow run deploy.yml \
      --repo  "$REPO" \
      --field stack_name="$ENV_NAME" \
      && ok "Workflow triggered" \
      || warn "Could not trigger workflow — push a commit to main instead"
  done

  # ── Wait for pipelines to complete ─────────────────────────────────────────
  if [ -n "$BACKEND_REPO" ] && [ -n "$FRONTEND_REPO" ]; then
    echo ""
    step "Waiting for CI pipelines to complete..."
    echo "  Backend pipeline  (~5-8 min): $BACKEND_REPO"
    echo "  Frontend pipeline (~3-5 min): $FRONTEND_REPO"
    echo "  (Total estimated: ~8-10 minutes)"
    echo ""

    # Small delay to let GitHub register the triggered runs
    sleep 15

    echo "  Monitoring backend deployment..."
    gh run watch --exit-status --repo "$BACKEND_REPO" \
      && ok "Backend deployment succeeded" \
      || warn "Backend run check failed — verify at: https://github.com/${BACKEND_REPO}/actions"

    echo ""
    echo "  Monitoring frontend deployment..."
    gh run watch --exit-status --repo "$FRONTEND_REPO" \
      && ok "Frontend deployment succeeded" \
      || warn "Frontend run check failed — verify at: https://github.com/${FRONTEND_REPO}/actions"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Final summary
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              Demo Infrastructure Ready!          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "  🌐 Demo URL (share with attendees):"
echo "       $FRONTEND_URL"
echo ""
echo "  🔧 Backend API:"
echo "       $BACKEND_URL"
echo ""
echo "  📚 Swagger / OpenAPI UI:"
echo "       ${BACKEND_URL}/swagger-ui.html"
echo ""
echo "  ℹ️  If services show 503, CI is still deploying."
echo "     Wait a few minutes and refresh."
echo ""
echo "────────────────────────────────────────────────────"
echo "  After the demo, free your tier:"
echo "    cd $(dirname "$SCRIPTS_DIR")"
echo "    ./scripts/teardown-stack.sh $ENV_NAME $AWS_REGION"
echo "────────────────────────────────────────────────────"
echo ""
echo "  Setup completed at: $(date)"
