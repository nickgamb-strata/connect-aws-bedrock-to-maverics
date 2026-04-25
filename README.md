# Connect AWS Bedrock to Maverics

A self-contained example that connects an AWS Bedrock AgentCore agent to a Maverics AI Identity Gateway acting as an MCP server. The same gateway from the [Claude Code tutorial](https://github.com/nickgamb-strata/connect-claude-to-maverics), rewired for a Bedrock agent client.

Companion to the blog post: *Plug AWS Bedrock Into Your Identity Layer. Same Gateway. Different Agent.* on [maverics.ai](https://www.maverics.ai/blog).

## What you get

- A Maverics AI Identity Gateway protecting two MCP backends (Enterprise Ledger and Employee Directory) with OAuth 2.0, OPA policies, and RFC 8693 token exchange.
- A Bedrock AgentCore Gateway that calls the Maverics MCP server on behalf of an end user (3LO Authorization Code) or as a service (2LO Client Credentials).
- A Cloudflare Tunnel exposing the local Maverics endpoints to AgentCore over HTTPS.

## Prerequisites

- Docker Desktop (or Docker Engine + Compose v2).
- [mkcert](https://github.com/FiloSottile/mkcert) for local TLS.
- [jq](https://stedolan.github.io/jq/) for parsing AWS responses (`brew install jq`).
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html).
- [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/install-and-setup/installation/) (`brew install cloudflared`).
- A Maverics Orchestrator image from [Strata](https://www.strata.io/) loaded via `docker load`.
- An AWS account with admin access (see "AWS account walkthrough" below).
- A Cloudflare account (free tier is fine) with a domain you control.

## High-level walkthrough

```
1. Stand up the local lab.
2. Set up an AWS account if you do not have one.
3. Create an IAM user, configure the AWS CLI.
4. Request Bedrock model access.
5. Run the Cloudflare Tunnel.
6. Run scripts/aws-bootstrap.sh to create the gateway IAM role.
7. Run scripts/agentcore-setup.sh to create the gateway and target.
8. Complete the one-time OAuth admin consent in the AWS console.
9. Invoke an agent.
```

## 1. Stand up the local lab

```bash
make init                  # generate certs, OIDC keys, configure local DNS
cp .env.example .env       # then edit MAVERICS_IMAGE and other values
make up                    # docker compose up -d --build
make smoke-test            # verify services are healthy
```

The lab is functionally identical to the prior tutorial. Same containers, same backends, same OPA policies. The OIDC Provider has a new `bedrock-agentcore` client added alongside `mcp-client-cli`. The AI Identity Gateway has the public Cloudflare hostname added to its allowed audiences.

## 2. AWS account walkthrough

Skip this section if you already have an AWS account.

1. Sign up at [aws.amazon.com](https://aws.amazon.com). New accounts get $200 in starter credits across the first months. A payment method is required even with credits.
2. After sign-up, open the AWS console and switch to **us-east-1** (top right region selector). Bedrock AgentCore is GA in eight regions; this tutorial uses us-east-1.
3. In the IAM console, create a non-root user named `maverics-tutorial` with **Programmatic access**.
4. Attach the policy from `aws/iam-policy.json` to the user (Inline policy, JSON tab, paste the file).
5. Generate an access key for the user and save the credentials.
6. Install the AWS CLI v2 if you have not already, then configure:
   ```bash
   aws configure
   # AWS Access Key ID: <your key>
   # AWS Secret Access Key: <your secret>
   # Default region: us-east-1
   # Default output: json
   ```
7. Request Bedrock model access in the console: **Bedrock > Model access > Modify model access**, enable **Anthropic Claude 3.5 Sonnet v2**. Approval is usually instant.

Cost note. Claude 3.5 Sonnet on Bedrock is roughly $3 per million input tokens and $15 per million output tokens. A short demo session of a hundred tool calls is well under a dollar. AgentCore agents do internal LLM calls for planning, so a single user prompt can spawn five or more model invocations. Run `make agentcore-down` when done so you stop paying for the gateway and target.

## 3. Cloudflare Tunnel

AgentCore runs in AWS. The lab runs on `localhost`. We expose the gateway and OIDC Provider over public HTTPS via [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/).

```bash
cloudflared tunnel login                          # opens browser, authorizes a Cloudflare zone
cloudflared tunnel create maverics-lab             # writes ~/.cloudflared/<id>.json
cloudflared tunnel list                            # note the tunnel id
```

Add DNS records for the two hostnames you will use:

```bash
cloudflared tunnel route dns maverics-lab auth.<your-domain>
cloudflared tunnel route dns maverics-lab gateway.<your-domain>
```

Copy the tunnel config template and fill in the values:

```bash
cp cloudflared/config.yml.template cloudflared/config.yml
# Edit cloudflared/config.yml:
#   tunnel: <TUNNEL-ID>
#   credentials-file: /Users/<you>/.cloudflared/<TUNNEL-ID>.json
#   replace auth.example.com / gateway.example.com with your hostnames
```

Update `.env`:

```bash
BEDROCK_GATEWAY_HOSTNAME=gateway.<your-domain>
BEDROCK_AUTH_HOSTNAME=auth.<your-domain>
```

Update the Maverics configs to add the same public hostnames in two places:

- `orchestrator/oidc-provider/maverics.yaml`, `apps[bedrock-agentcore].allowedAudiences`. Replace `https://gateway.example.com/` with `https://gateway.<your-domain>/`.
- `orchestrator/ai-identity-gateway/maverics.yaml`, `mcpProvider.authorization.oauth.servers[0].tokenValidation.expectedAudiences`. Same replacement.

Restart the orchestrator containers to pick up the changes:

```bash
docker compose restart oidc-config-merge oidc-provider ai-identity-gateway
```

Run the tunnel in a separate terminal:

```bash
make tunnel
```

Verify from a second machine or browser that `https://auth.<your-domain>/.well-known/oauth-authorization-server` returns the Maverics issuer JSON.

## 4. Bootstrap AWS

One-time IAM role creation for the AgentCore Gateway.

```bash
source .env                              # load env vars
make agentcore-bootstrap                 # creates bedrock-agentcore-maverics-role
```

The script prints the role ARN. Copy it into `.env`:

```bash
AGENTCORE_ROLE_ARN=arn:aws:iam::<account>:role/bedrock-agentcore-maverics-role
```

## 5. Set up the Gateway and target (3LO default)

```bash
source .env
make agentcore-up
```

This script:
1. Creates an OAuth2 credential provider in AgentCore that points at the Maverics OIDC Provider over the tunnel.
2. Reads back the AgentCore-generated callback URL.
3. Pauses for you to add that callback URL to the `bedrock-agentcore` client's `redirectURLs` in `orchestrator/oidc-provider/maverics.yaml`, then restart the OIDC Provider.
4. Creates the AgentCore Gateway with `--protocol-type MCP` and `--authorizer-type NONE` (we are not exposing AgentCore as an MCP server here, just consuming our Maverics MCP server).
5. Creates the MCP target with `grantType=AUTHORIZATION_CODE` and the OAuth2 credential provider you just created.

## 6. One-time admin OAuth consent

Open the AWS console: **Bedrock > AgentCore > Gateways > maverics-gateway > Targets > maverics-mcp**.

Click **Authorize**. AgentCore opens a browser window that redirects to the Maverics OIDC Provider, which federates to Keycloak. Sign in as a test user:

| User | Email | Password |
|------|-------|----------|
| John McClane | john.mcclane@orchestrator.lab | yippiekayay |
| Sarah Connor | sarah.connor@orchestrator.lab | judgmentday |

After consent the target moves to **READY**. AgentCore caches the access and refresh tokens.

## 7. Invoke an agent

Create an AgentCore agent in the console (Bedrock > AgentCore > Agents > Create) and attach the `maverics-gateway` you just made. Pick **Anthropic Claude 3.5 Sonnet v2** as the model. Test the agent with a prompt like:

> List the first three accounts in the enterprise ledger.

The agent invokes `enterprise_ledger_listAccounts` via Maverics. Watch the gateway logs:

```bash
docker compose logs -f ai-identity-gateway
```

You should see one inbound MCP request, the OPA inbound policy evaluating, an RFC 8693 token exchange to mint a delegation token, and the upstream backend call. The Enterprise Ledger logs will show the request as the Keycloak user.

## 2LO sidebar (service-to-service)

Some workloads do not have an end user. For those:

```bash
source .env
make agentcore-up-2lo
```

This creates an alternate gateway and target with `grantType=CLIENT_CREDENTIALS`. The agent authenticates as itself, so the audit log shows the agent's service identity rather than a human. Default to 3LO unless there is genuinely no user driving the request.

## Cleaning up

```bash
make agentcore-down       # delete the gateway, target, and OAuth credential provider
make down                 # stop and remove all containers
```

The IAM role from `aws-bootstrap.sh` is left in place. Remove it manually if you want a clean slate:

```bash
aws iam delete-role-policy --role-name bedrock-agentcore-maverics-role --policy-name bedrock-agentcore-maverics-role-inline
aws iam delete-role --role-name bedrock-agentcore-maverics-role
```

## Architecture

```
Bedrock AgentCore (AWS)
        │
        ▼  HTTPS (Cloudflare Tunnel)
   cloudflared
        │
        ▼  (re-headers to *.orchestrator.lab)
   Envoy (TLS termination, mTLS to gateway)
        │
        ▼  mTLS
   AI Identity Gateway (Maverics)
        ├── mcpProvider (validates AgentCore token, runs OPA)
        ├── mcpProxy → Enterprise Ledger (Go MCP server)
        └── mcpBridge → Employee Directory (Go REST API)
              │
              ▼  RFC 8693 token exchange
        OIDC Provider (Maverics) ←→ Keycloak (IdP)
              │
              ▼
        Redis (cache) + Vault (secrets)
```

## MCP tools available

| Namespace | Tool | Scope | Access |
|-----------|------|-------|--------|
| enterprise_ledger_ | listAccounts | ledger:ListAccounts | All authenticated users |
| enterprise_ledger_ | getAccount | ledger:GetAccount | All authenticated users |
| enterprise_ledger_ | getTransactions | ledger:ListTransactions | All authenticated users |
| enterprise_ledger_ | updateAccountStatus | ledger:UpdateAccount | All authenticated users |
| enterprise_ledger_ | getCustomerPII | ledger:ReadPII | Requires `pii:read` scope |
| enterprise_ledger_ | getAuditLog | ledger:ReadAudit | Requires `audit:read` scope |
| employee_directory_ | listEmployees | employee:List | All authenticated users |
| employee_directory_ | getEmployee | employee:Get | All authenticated users |
| employee_directory_ | createEmployee | employee:Create | All authenticated users |
| employee_directory_ | updateEmployee | employee:Update | All authenticated users |
| employee_directory_ | deactivateEmployee | employee:Deactivate | All authenticated users |
| employee_directory_ | getDirectReports | employee:List | All authenticated users |
| employee_directory_ | listDepartments | department:List | All authenticated users |

## Key files

| File | Purpose |
|------|---------|
| `orchestrator/oidc-provider/maverics.yaml` | OAuth authorization server config (includes `bedrock-agentcore` client) |
| `orchestrator/ai-identity-gateway/maverics.yaml` | MCP gateway config (includes the public Cloudflare audience) |
| `orchestrator/ai-identity-gateway/policies/*.rego` | OPA authorization policies |
| `cloudflared/config.yml.template` | Cloudflare Tunnel routing template |
| `aws/iam-policy.json` | Least-privilege IAM policy for the tutorial user |
| `aws/gateway-trust-policy.json` | Trust policy assumed by the AgentCore service |
| `aws/gateway-role-policy.json` | Permissions the gateway role needs |
| `scripts/aws-bootstrap.sh` | Creates the gateway IAM role |
| `scripts/agentcore-setup.sh` | Creates the OAuth provider, gateway, and target (3LO) |
| `scripts/agentcore-setup-2lo.sh` | Same with `CLIENT_CREDENTIALS` for service-to-service |
| `scripts/agentcore-teardown.sh` | Tears down the gateway, target, and OAuth provider |

## Makefile targets

| Target | Description |
|--------|-------------|
| `make init` | Generate TLS certs, OIDC keys, configure DNS |
| `make up` | Start the local lab |
| `make down` | Stop and remove containers and volumes |
| `make logs` | Tail container logs |
| `make smoke-test` | Verify the lab is healthy |
| `make tunnel` | Run the Cloudflare Tunnel |
| `make agentcore-bootstrap` | Create the IAM role for AgentCore |
| `make agentcore-up` | Create the AgentCore Gateway and MCP target (3LO) |
| `make agentcore-up-2lo` | Same with Client Credentials (2LO) |
| `make agentcore-down` | Tear down the AgentCore Gateway and target |

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `mkcert: command not found` | `brew install mkcert` (macOS) or see [mkcert docs](https://github.com/FiloSottile/mkcert#installation) |
| `cloudflared: command not found` | `brew install cloudflared` (macOS) or see [Cloudflare docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/install-and-setup/installation/) |
| Cloudflare DNS records not resolving | Wait a minute for propagation. Verify with `dig auth.<your-domain>` |
| AgentCore target stuck in CREATING | Check the gateway logs: `docker compose logs ai-identity-gateway`. Tokens may have a wrong audience |
| OAuth callback fails after admin consent | Confirm the AgentCore-generated callback URL is in `redirectURLs` and the OIDC Provider was restarted |
| Token validation fails at the gateway | Confirm `expectedAudiences` includes the public Cloudflare hostname |
| AWS access denied creating gateway | Verify the IAM user has the policy from `aws/iam-policy.json` attached |
| `model access denied` on agent invoke | Check Bedrock > Model access for Claude 3.5 Sonnet v2 in your region |

## Further reading

- [Strata MCP Provider](https://docs.strata.io/reference/orchestrator/applications/mcp-provider)
- [Strata Token Brokering (experimental)](https://docs.strata.io/reference/orchestrator/experimental/token-brokering)
- [Bedrock AgentCore Gateway: MCP server targets](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-target-MCPservers.html)
- [Bedrock AgentCore Gateway: OAuth authentication](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-oauth.html)
- [MCP specification: Authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
- [RFC 9728: OAuth 2.0 Protected Resource Metadata](https://datatracker.ietf.org/doc/html/rfc9728)
- [RFC 8693: OAuth 2.0 Token Exchange](https://datatracker.ietf.org/doc/html/rfc8693)
