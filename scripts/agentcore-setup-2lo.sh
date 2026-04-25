#!/usr/bin/env bash
# Set up an AgentCore Gateway and MCP target with 2LO Client Credentials.
# The agent authenticates as itself, no end-user identity. Use only when the
# workload genuinely has no human in the loop. Default path is 3LO; see
# scripts/agentcore-setup.sh.
set -euo pipefail

: "${AWS_REGION:=us-east-1}"
: "${AGENTCORE_GATEWAY_NAME:=maverics-gateway-2lo}"
: "${AGENTCORE_TARGET_NAME:=maverics-mcp-2lo}"
: "${AGENTCORE_OAUTH_PROVIDER_NAME:=maverics-oauth-provider-2lo}"
: "${AGENTCORE_ROLE_ARN:?AGENTCORE_ROLE_ARN must be set (run scripts/aws-bootstrap.sh first)}"
: "${BEDROCK_GATEWAY_HOSTNAME:?BEDROCK_GATEWAY_HOSTNAME must be set}"
: "${BEDROCK_AUTH_HOSTNAME:?BEDROCK_AUTH_HOSTNAME must be set}"
: "${BEDROCK_OAUTH_CLIENT_ID:=bedrock-agentcore}"
: "${BEDROCK_OAUTH_CLIENT_SECRET:?BEDROCK_OAUTH_CLIENT_SECRET must be set}"

echo "==> Creating OAuth2 credential provider: ${AGENTCORE_OAUTH_PROVIDER_NAME}"
PROVIDER_ARN=$(aws bedrock-agentcore-control create-oauth2-credential-provider \
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
  }' | jq -r '.credentialProviderArn')

echo "    Provider ARN: ${PROVIDER_ARN}"

echo "==> Creating Gateway: ${AGENTCORE_GATEWAY_NAME}"
GATEWAY_ID=$(aws bedrock-agentcore-control create-gateway \
  --region "${AWS_REGION}" \
  --name "${AGENTCORE_GATEWAY_NAME}" \
  --role-arn "${AGENTCORE_ROLE_ARN}" \
  --protocol-type MCP \
  --authorizer-type NONE \
  --description "Maverics MCP Gateway via AgentCore (2LO sidebar)" | jq -r '.gatewayId')

echo "    Gateway ID: ${GATEWAY_ID}"

echo "==> Creating MCP target with CLIENT_CREDENTIALS"
TARGET_CONFIG=$(cat <<EOF
{
  "mcp": {
    "mcpServer": {
      "endpoint": "https://${BEDROCK_GATEWAY_HOSTNAME}/mcp",
      "listingMode": "DEFAULT"
    }
  }
}
EOF
)

CRED_CONFIG=$(cat <<EOF
[
  {
    "credentialProviderType": "OAUTH",
    "credentialProvider": {
      "oauthCredentialProvider": {
        "providerArn": "${PROVIDER_ARN}",
        "scopes": ["pii:read", "audit:read"],
        "grantType": "CLIENT_CREDENTIALS"
      }
    }
  }
]
EOF
)

aws bedrock-agentcore-control create-gateway-target \
  --region "${AWS_REGION}" \
  --gateway-identifier "${GATEWAY_ID}" \
  --name "${AGENTCORE_TARGET_NAME}" \
  --target-configuration "${TARGET_CONFIG}" \
  --credential-provider-configurations "${CRED_CONFIG}" \
  --description "Maverics MCP server (2LO)" \
  >/dev/null

echo ""
echo "==> 2LO setup complete."
echo "    Tokens issued by Maverics will not include an end-user sub."
echo "    The agent acts as itself. Default path is 3LO; see scripts/agentcore-setup.sh."
