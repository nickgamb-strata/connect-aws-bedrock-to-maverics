#!/usr/bin/env bash
# One-time AWS bootstrap. Creates the IAM role the AgentCore Gateway will assume.
# Run after `aws configure`. Idempotent: re-running is a no-op if the role exists.
set -euo pipefail

: "${AWS_REGION:=us-east-1}"
: "${AGENTCORE_ROLE_NAME:=bedrock-agentcore-maverics-role}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Creating IAM role: ${AGENTCORE_ROLE_NAME}"
if aws iam get-role --role-name "${AGENTCORE_ROLE_NAME}" >/dev/null 2>&1; then
  echo "    Role already exists. Updating inline policy."
else
  aws iam create-role \
    --role-name "${AGENTCORE_ROLE_NAME}" \
    --assume-role-policy-document "file://${ROOT_DIR}/aws/gateway-trust-policy.json" \
    --description "Role assumed by Bedrock AgentCore Gateway for Maverics lab" \
    >/dev/null
fi

echo "==> Attaching inline policy to role"
aws iam put-role-policy \
  --role-name "${AGENTCORE_ROLE_NAME}" \
  --policy-name "${AGENTCORE_ROLE_NAME}-inline" \
  --policy-document "file://${ROOT_DIR}/aws/gateway-role-policy.json"

ROLE_ARN=$(aws iam get-role \
  --role-name "${AGENTCORE_ROLE_NAME}" \
  --query 'Role.Arn' --output text)

echo ""
echo "==> Bootstrap complete."
echo "    Role ARN: ${ROLE_ARN}"
echo ""
echo "    Add this to .env:"
echo "      AGENTCORE_ROLE_ARN=${ROLE_ARN}"
