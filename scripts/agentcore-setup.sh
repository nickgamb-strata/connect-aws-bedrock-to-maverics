#!/usr/bin/env bash
# Set up the AgentCore Gateway and MCP target with 3LO Authorization Code.
# Prereqs: AWS CLI configured, scripts/aws-bootstrap.sh has been run, the
# Cloudflare Tunnel is up, and BEDROCK_GATEWAY_HOSTNAME / BEDROCK_AUTH_HOSTNAME
# point to your tunnel hostnames.
set -euo pipefail

: "${AWS_REGION:=us-east-1}"
: "${AGENTCORE_GATEWAY_NAME:=maverics-gateway}"
: "${AGENTCORE_TARGET_NAME:=maverics-mcp}"
: "${AGENTCORE_OAUTH_PROVIDER_NAME:=maverics-oauth-provider}"
: "${AGENTCORE_ROLE_ARN:?AGENTCORE_ROLE_ARN must be set (run scripts/aws-bootstrap.sh first)}"
: "${BEDROCK_GATEWAY_HOSTNAME:?BEDROCK_GATEWAY_HOSTNAME must be set (your Cloudflare Tunnel hostname for the gateway, e.g. gateway.example.com)}"
: "${BEDROCK_AUTH_HOSTNAME:?BEDROCK_AUTH_HOSTNAME must be set (your Cloudflare Tunnel hostname for the OIDC provider, e.g. auth.example.com)}"
: "${BEDROCK_OAUTH_CLIENT_ID:=bedrock-agentcore}"
: "${BEDROCK_OAUTH_CLIENT_SECRET:?BEDROCK_OAUTH_CLIENT_SECRET must be set (the same value stored under bedrock_agentcore.client_secret in secrets.yaml)}"

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
CALLBACK_URL=$(echo "${PROVIDER_OUTPUT}" | jq -r '.callbackUrl')

echo "    Provider ARN: ${PROVIDER_ARN}"
echo "    Callback URL: ${CALLBACK_URL}"
echo ""
echo "==> ACTION REQUIRED:"
echo "    1. Add this redirect URL to orchestrator/oidc-provider/maverics.yaml"
echo "       under the bedrock-agentcore client's redirectURLs:"
echo ""
echo "       ${CALLBACK_URL}"
echo ""
echo "    2. Restart the OIDC Provider container so it picks up the change:"
echo "       docker compose restart oidc-config-merge oidc-provider"
echo ""
read -r -p "Press enter once the redirect URL is registered and the container has restarted."

echo "==> Creating Gateway: ${AGENTCORE_GATEWAY_NAME}"
GATEWAY_OUTPUT=$(aws bedrock-agentcore-control create-gateway \
  --region "${AWS_REGION}" \
  --name "${AGENTCORE_GATEWAY_NAME}" \
  --role-arn "${AGENTCORE_ROLE_ARN}" \
  --protocol-type MCP \
  --authorizer-type NONE \
  --description "Maverics MCP Gateway via AgentCore")

GATEWAY_ID=$(echo "${GATEWAY_OUTPUT}" | jq -r '.gatewayId')
echo "    Gateway ID: ${GATEWAY_ID}"

echo "==> Creating MCP target: ${AGENTCORE_TARGET_NAME}"
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
        "grantType": "AUTHORIZATION_CODE"
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
  --description "Maverics AI Identity Gateway MCP server" \
  >/dev/null

echo ""
echo "==> Setup complete."
echo "    Next step: complete the one-time admin OAuth consent in the AWS console."
echo "    Bedrock > AgentCore > Gateways > ${AGENTCORE_GATEWAY_NAME} > Targets > ${AGENTCORE_TARGET_NAME}"
echo "    Click 'Authorize'. Sign in as a Keycloak test user (john.mcclane / yippiekayay)."
echo ""
echo "    Once the target shows READY you can invoke an agent that uses this gateway."
