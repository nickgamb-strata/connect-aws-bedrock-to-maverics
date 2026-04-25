#!/usr/bin/env bash
# Set up the AgentCore Gateway and MCP target with 2LO Client Credentials.
# The verified-working tutorial path. The agent authenticates as itself, no
# end-user identity. Per-user delegation (3LO) requires aligning Maverics' OIDC
# issuer with the public Cloudflare hostname and is out of scope for this lab.
#
# Prereqs:
#   - AWS CLI configured (`aws configure`)
#   - scripts/aws-bootstrap.sh has been run (creates the gateway IAM role)
#   - Cloudflare Tunnel is up (`make tunnel`)
#   - .env has BEDROCK_GATEWAY_HOSTNAME / BEDROCK_AUTH_HOSTNAME pointing to
#     your tunnel hostnames, and BEDROCK_OAUTH_CLIENT_SECRET matches the value
#     in secrets.yaml under bedrock_agentcore.client_secret.
set -euo pipefail

: "${AWS_REGION:=us-west-2}"
: "${AGENTCORE_GATEWAY_NAME:=maverics-gateway}"
: "${AGENTCORE_TARGET_NAME:=maverics-mcp}"
: "${AGENTCORE_OAUTH_PROVIDER_NAME:=maverics-oauth-provider}"
: "${AGENTCORE_ROLE_ARN:?AGENTCORE_ROLE_ARN must be set (run scripts/aws-bootstrap.sh first)}"
: "${BEDROCK_GATEWAY_HOSTNAME:?BEDROCK_GATEWAY_HOSTNAME must be set (your Cloudflare Tunnel hostname for the gateway)}"
: "${BEDROCK_AUTH_HOSTNAME:?BEDROCK_AUTH_HOSTNAME must be set (your Cloudflare Tunnel hostname for the OIDC provider)}"
: "${BEDROCK_OAUTH_CLIENT_ID:=bedrock-agentcore}"
: "${BEDROCK_OAUTH_CLIENT_SECRET:?BEDROCK_OAUTH_CLIENT_SECRET must be set}"

echo "==> Creating OAuth2 credential provider: ${AGENTCORE_OAUTH_PROVIDER_NAME}"
PROVIDER_OUTPUT=$(aws bedrock-agentcore-control create-oauth2-credential-provider \
  --region "${AWS_REGION}" \
  --name "${AGENTCORE_OAUTH_PROVIDER_NAME}" \
  --credential-provider-vendor CustomOauth2 \
  --oauth2-provider-config-input '{
    "customOauth2ProviderConfig": {
      "oauthDiscovery": {
        "authorizationServerMetadata": {
          "issuer": "https://'"${BEDROCK_AUTH_HOSTNAME}"'",
          "authorizationEndpoint": "https://'"${BEDROCK_AUTH_HOSTNAME}"'/oauth2/auth",
          "tokenEndpoint": "https://'"${BEDROCK_AUTH_HOSTNAME}"'/oauth2/token",
          "responseTypes": ["code"],
          "tokenEndpointAuthMethods": ["client_secret_post"]
        }
      },
      "clientId": "'"${BEDROCK_OAUTH_CLIENT_ID}"'",
      "clientSecret": "'"${BEDROCK_OAUTH_CLIENT_SECRET}"'"
    }
  }')

PROVIDER_ARN=$(echo "${PROVIDER_OUTPUT}" | jq -r '.credentialProviderArn')

echo "    Provider ARN: ${PROVIDER_ARN}"

echo "==> Creating Gateway: ${AGENTCORE_GATEWAY_NAME}"
echo "    --exception-level DEBUG so tool-call errors return detailed messages."
GATEWAY_OUTPUT=$(aws bedrock-agentcore-control create-gateway \
  --region "${AWS_REGION}" \
  --name "${AGENTCORE_GATEWAY_NAME}" \
  --role-arn "${AGENTCORE_ROLE_ARN}" \
  --protocol-type MCP \
  --authorizer-type NONE \
  --exception-level DEBUG \
  --description "Maverics MCP Gateway via AgentCore (2LO)")

GATEWAY_ID=$(echo "${GATEWAY_OUTPUT}" | jq -r '.gatewayId')
GATEWAY_URL=$(echo "${GATEWAY_OUTPUT}" | jq -r '.gatewayUrl')
echo "    Gateway ID: ${GATEWAY_ID}"
echo "    Gateway URL (for agents to call): ${GATEWAY_URL}"

echo "==> Creating MCP target: ${AGENTCORE_TARGET_NAME}"
TARGET_CONFIG=$(cat <<EOF
{"mcp":{"mcpServer":{"endpoint":"https://${BEDROCK_GATEWAY_HOSTNAME}/mcp","listingMode":"DEFAULT"}}}
EOF
)

CRED_CONFIG=$(cat <<EOF
[{"credentialProviderType":"OAUTH","credentialProvider":{"oauthCredentialProvider":{"providerArn":"${PROVIDER_ARN}","scopes":["pii:read","audit:read"],"grantType":"CLIENT_CREDENTIALS"}}}]
EOF
)

aws bedrock-agentcore-control create-gateway-target \
  --region "${AWS_REGION}" \
  --gateway-identifier "${GATEWAY_ID}" \
  --name "${AGENTCORE_TARGET_NAME}" \
  --target-configuration "${TARGET_CONFIG}" \
  --credential-provider-configurations "${CRED_CONFIG}" \
  --description "Maverics MCP server" \
  >/dev/null

echo ""
echo "==> Setup complete."
echo "    AgentCore Gateway URL (use this in the demo):"
echo "      ${GATEWAY_URL}"
echo ""
echo "    Wait until the target reports READY:"
echo "      aws bedrock-agentcore-control get-gateway-target \\"
echo "        --region ${AWS_REGION} \\"
echo "        --gateway-identifier ${GATEWAY_ID} \\"
echo "        --target-id <printed by create-gateway-target>"
echo ""
echo "    Then run the demo:"
echo "      AGENTCORE_GATEWAY_URL=${GATEWAY_URL} make agentcore-demo"
