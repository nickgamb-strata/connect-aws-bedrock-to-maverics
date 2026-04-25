#!/usr/bin/env bash
# Tear down the AgentCore Gateway, target, and OAuth credential provider.
# Run this when you are done with the lab to stop incurring AWS costs.
set -euo pipefail

: "${AWS_REGION:=us-east-1}"
: "${AGENTCORE_GATEWAY_NAME:=maverics-gateway}"
: "${AGENTCORE_TARGET_NAME:=maverics-mcp}"
: "${AGENTCORE_OAUTH_PROVIDER_NAME:=maverics-oauth-provider}"

echo "==> Locating gateway: ${AGENTCORE_GATEWAY_NAME}"
GATEWAY_ID=$(aws bedrock-agentcore-control list-gateways \
  --region "${AWS_REGION}" \
  --query "gateways[?name=='${AGENTCORE_GATEWAY_NAME}'].gatewayId | [0]" \
  --output text 2>/dev/null || echo "")

if [ -z "${GATEWAY_ID}" ] || [ "${GATEWAY_ID}" = "None" ]; then
  echo "    No gateway named ${AGENTCORE_GATEWAY_NAME} found. Skipping."
else
  echo "    Found gateway ${GATEWAY_ID}"

  echo "==> Listing targets on gateway"
  TARGET_IDS=$(aws bedrock-agentcore-control list-gateway-targets \
    --region "${AWS_REGION}" \
    --gateway-identifier "${GATEWAY_ID}" \
    --query 'gatewayTargets[].targetId' --output text 2>/dev/null || echo "")

  for TARGET_ID in ${TARGET_IDS}; do
    echo "    Deleting target ${TARGET_ID}"
    aws bedrock-agentcore-control delete-gateway-target \
      --region "${AWS_REGION}" \
      --gateway-identifier "${GATEWAY_ID}" \
      --target-id "${TARGET_ID}" >/dev/null
  done

  echo "==> Deleting gateway ${GATEWAY_ID}"
  aws bedrock-agentcore-control delete-gateway \
    --region "${AWS_REGION}" \
    --gateway-identifier "${GATEWAY_ID}" >/dev/null
fi

echo "==> Deleting OAuth credential provider: ${AGENTCORE_OAUTH_PROVIDER_NAME}"
if aws bedrock-agentcore-control delete-oauth2-credential-provider \
  --region "${AWS_REGION}" \
  --name "${AGENTCORE_OAUTH_PROVIDER_NAME}" >/dev/null 2>&1; then
  echo "    Deleted."
else
  echo "    Not found or already deleted. Skipping."
fi

echo ""
echo "==> Teardown complete."
echo "    The IAM role from scripts/aws-bootstrap.sh is left in place. Delete it"
echo "    manually with: aws iam delete-role-policy --role-name <role> --policy-name <name>"
echo "                   aws iam delete-role --role-name <role>"
