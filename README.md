# Connect AWS Bedrock to Maverics

A self-contained example that connects an AWS Bedrock AgentCore Gateway to a Maverics AI Identity Gateway acting as an MCP server. Same gateway, OPA policies, and backends from the [Claude Code tutorial](https://github.com/nickgamb-strata/connect-claude-to-maverics), rewired for a Bedrock agent client and exposed through a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) so AgentCore in AWS can reach the local lab.

Companion to the blog post: [Connect AWS Bedrock AgentCore to an OAuth-Protected MCP Server: A Step-by-Step Tutorial](https://www.maverics.ai/blog).

## What you get

- A Maverics AI Identity Gateway protecting two MCP backends (Enterprise Ledger and Employee Directory) with OAuth 2.0, OPA policies, and RFC 8693 token exchange.
- A Bedrock AgentCore Gateway that obtains a 2LO Client Credentials token from Maverics and forwards MCP tool calls on behalf of the agent.
- A Cloudflare Tunnel exposing the local Maverics endpoints over public HTTPS.

## What's verified end to end

This tutorial drives the full chain: Bedrock client &rarr; AgentCore Gateway &rarr; Cloudflare Tunnel &rarr; Maverics MCP gateway &rarr; OPA inbound policy &rarr; RFC 8693 token exchange &rarr; Enterprise Ledger / Employee Directory backends. `make agentcore-demo` (covered below) confirms each link.

3LO Authorization Code with PKCE is a natural extension but requires aligning Maverics' OIDC issuer with the public Cloudflare hostname (and updating Keycloak redirect URIs). Out of scope for this lab.

## Prerequisites

- Docker Desktop or Docker Engine + Compose v2.
- [mkcert](https://github.com/FiloSottile/mkcert) for local TLS.
- [jq](https://stedolan.github.io/jq/), [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html), and [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/install-and-setup/installation/). On macOS: `brew install awscli cloudflared jq mkcert`.
- A Maverics Orchestrator image from [Strata](https://www.strata.io/) loaded via `docker load`.
- An AWS account in a Bedrock AgentCore GA region (us-east-1, us-west-2, ap-south-1, ap-southeast-1, ap-southeast-2, ap-northeast-1, eu-central-1, eu-west-1).
- A Cloudflare account with a domain you control (free tier is enough).

## High-level walkthrough

```
1. Stand up the local lab.
2. Configure AWS (IAM user + CLI).
3. Create the Cloudflare Tunnel and DNS records.
4. Run scripts/aws-bootstrap.sh to create the gateway IAM role.
5. Run scripts/agentcore-setup.sh to create the gateway and target.
6. Run scripts/agentcore-demo.sh to verify end-to-end.
7. (Optional) Create an AgentCore agent in the console and prompt it.
```

## 1. Stand up the local lab

```bash
make init                  # generate certs, OIDC keys, configure local DNS
cp .env.example .env       # then edit MAVERICS_IMAGE and other values
make up                    # docker compose up -d --build
make smoke-test            # verify services are healthy
```

The lab is functionally identical to the prior tutorial. Same containers, same backends, same OPA policies. The OIDC Provider has a new `bedrock-agentcore` client added alongside `mcp-client-cli`. The AI Identity Gateway accepts the `auth.orchestrator.lab` audience (Maverics defaults `aud` to the issuer URL on Client Credentials grants).

## 2. AWS account walkthrough

Skip this section if you already have AWS configured.

1. Sign up at [aws.amazon.com](https://aws.amazon.com) and add a payment method. New accounts get $200 in starter credits.
2. In the console, switch to **us-west-2** (top right region selector).
3. In **IAM > Users**, create a non-root user named `maverics-tutorial` with **Programmatic access**.
4. Attach the policy from `aws/iam-policy.json` to the user as an inline policy (Inline policy &rarr; JSON tab &rarr; paste the file).
5. Generate an access key for the user.
6. Configure the AWS CLI:
   ```bash
   aws configure
   # AWS Access Key ID: <your key>
   # AWS Secret Access Key: <your secret>
   # Default region: us-west-2
   # Default output: json
   ```
7. Bedrock model access. AWS retired the Model access page; serverless models auto-enable on first invoke. Confirm modern Anthropic models are available:
   ```bash
   aws bedrock list-inference-profiles --region us-west-2 --type-equals SYSTEM_DEFINED \
     --query "inferenceProfileSummaries[?contains(inferenceProfileId, 'sonnet-4-5') || contains(inferenceProfileId, 'haiku-4-5')].inferenceProfileId" \
     --output text
   ```
   You should see `us.anthropic.claude-sonnet-4-5-20250929-v1:0` and similar. The tutorial uses Claude Sonnet 4.5 (or Haiku 4.5 for cheaper runs).

Cost note. Claude Sonnet 4.5 on Bedrock is roughly $3 per million input tokens and $15 per million output tokens; Haiku 4.5 is about a tenth of that. A short demo session of a hundred tool calls is well under a dollar on Sonnet. AgentCore agents do internal LLM calls for planning, so a single user prompt can spawn five or more model invocations. Run `make agentcore-down` when done so you stop paying for the gateway.

## 3. Cloudflare Tunnel

AgentCore runs in AWS. The lab runs on `localhost`. We expose the gateway and OIDC Provider over public HTTPS via [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/).

```bash
cloudflared tunnel login                          # opens browser, authorizes a Cloudflare zone
cloudflared tunnel create maverics-lab            # writes ~/.cloudflared/<id>.json
cloudflared tunnel list                           # note the tunnel id

cloudflared tunnel route dns maverics-lab auth.<your-domain>
cloudflared tunnel route dns maverics-lab gateway.<your-domain>
```

Build the tunnel config:

```bash
cp cloudflared/config.yml.template cloudflared/config.yml
# Edit cloudflared/config.yml:
#   tunnel: <TUNNEL-ID>
#   credentials-file: /Users/<you>/.cloudflared/<TUNNEL-ID>.json
#   replace auth.example.com with auth.<your-domain>
#   replace gateway.example.com with gateway.<your-domain>
```

Update `.env`:

```bash
BEDROCK_GATEWAY_HOSTNAME=gateway.<your-domain>
BEDROCK_AUTH_HOSTNAME=auth.<your-domain>
```

Update both Maverics configs to swap `gateway.example.com` (and `auth.example.com` if present) for your real hostnames in:

- `orchestrator/oidc-provider/maverics.yaml` &rarr; `apps[bedrock-agentcore].allowedAudiences`
- `orchestrator/ai-identity-gateway/maverics.yaml` &rarr; if you also want JWTs minted for `gateway.<your-domain>` to validate, append it under `mcpProvider.authorization.oauth.servers[0].tokenValidation.expectedAudiences`. The default lab config accepts only `https://auth.orchestrator.lab` (the issuer URL), which is what AgentCore Client Credentials produces.

Restart the orchestrator containers:

```bash
docker compose restart oidc-config-merge oidc-provider ai-identity-gateway
```

Run the tunnel in a separate terminal and leave it running:

```bash
make tunnel
```

Verify externally:

```bash
curl -s https://auth.<your-domain>/.well-known/openid-configuration | jq .issuer
# "https://auth.orchestrator.lab"
```

## 4. Bootstrap the gateway IAM role

One-time. Creates the IAM role AgentCore Gateway assumes, with permissions for workload identity, OAuth token retrieval, model invocation, and CloudWatch logs.

```bash
source .env
make agentcore-bootstrap
```

The script prints the role ARN. Copy it into `.env`:

```bash
AGENTCORE_ROLE_ARN=arn:aws:iam::<account>:role/bedrock-agentcore-maverics-role
```

## 5. Create the gateway and target

```bash
source .env
make agentcore-up
```

The script prints the AgentCore Gateway URL. Copy it.

The target stays in `CREATING` for ~30 seconds while AgentCore connects to your Maverics MCP server, fetches the tool list, and caches it. Wait for `READY`:

```bash
aws bedrock-agentcore-control list-gateway-targets --region us-west-2 \
  --gateway-identifier $(aws bedrock-agentcore-control list-gateways --region us-west-2 \
    --query "items[?name=='maverics-gateway'].gatewayId | [0]" --output text) \
  --query 'items[].{name:name,status:status}'
```

## 6. Demo it end to end

Set the gateway URL from the previous step and run the demo:

```bash
export AGENTCORE_GATEWAY_URL=https://maverics-gateway-<id>.gateway.bedrock-agentcore.us-west-2.amazonaws.com/mcp
make agentcore-demo
```

You should see:

```
==> 1. initialize
    session: <uuid>
==> 2. notifications/initialized
==> 3. tools/list
  - maverics-mcp___employee_directory_listEmployees
  - maverics-mcp___employee_directory_getEmployee
  - ...
  - maverics-mcp___enterprise_ledger_listAccounts
  - maverics-mcp___enterprise_ledger_getAccount
  - ...
==> 4. tools/call maverics-mcp___enterprise_ledger_listAccounts
isError: False
---
{
  "accounts": [
    {
      "id": "...",
      "account_number": "CHK-200001",
      "holder_name": "Boba Fett",
      "balance": 89100.75,
      ...
```

Tail the gateway log in another terminal to watch the delegation chain:

```bash
docker compose logs -f ai-identity-gateway
```

You should see `successfully validated access token`, `evaluating outbound authorization policy`, and `successfully completed token exchange` for each call. The exchanged delegation token has `subject=bedrock-agentcore` and `actor.sub=ai-identity-gateway`.

## 7. (Optional) Test from an AgentCore agent

Create an AgentCore agent in the console (Bedrock &rarr; AgentCore &rarr; Agents &rarr; Create) and attach the `maverics-gateway`. Pick **Claude Sonnet 4.5** as the model. In the test panel:

> List the first three accounts in the enterprise ledger.

The agent will discover and invoke `maverics-mcp___enterprise_ledger_listAccounts` through the same chain.

## Cleanup

```bash
make agentcore-down       # delete gateway, target, OAuth provider
make down                 # stop and remove all containers
```

The IAM role from `aws-bootstrap.sh` is left in place. Remove it manually if you want a clean slate:

```bash
aws iam delete-role-policy \
  --role-name bedrock-agentcore-maverics-role \
  --policy-name bedrock-agentcore-maverics-role-inline
aws iam delete-role --role-name bedrock-agentcore-maverics-role
```

## Architecture

```
Bedrock client / AgentCore Agent (AWS)
        |
        v   MCP over HTTPS
   AgentCore Gateway (AWS)
        |   2LO Client Credentials -> Maverics token endpoint
        |   then MCP tool call carrying the OAuth token
        v   HTTPS via Cloudflare Tunnel
   cloudflared (your laptop)
        |   re-headers to *.orchestrator.lab
        v
   Envoy (TLS termination, mTLS to gateway)
        |
        v   mTLS
   AI Identity Gateway (Maverics)
        |-- mcpProvider (validates AgentCore token, runs OPA)
        |-- mcpProxy   -> Enterprise Ledger (Go MCP server)
        |-- mcpBridge  -> Employee Directory (Go REST API)
              |
              v   RFC 8693 token exchange (delegation)
        OIDC Provider (Maverics) <-> Keycloak (IdP)
              |
              v
        Redis (cache) + Vault (secrets)
```

## MCP tools available

| Namespace | Tool | Scope | Access |
|-----------|------|-------|--------|
| enterprise_ledger_ | listAccounts | ledger:ListAccounts | All authenticated callers |
| enterprise_ledger_ | getAccount | ledger:GetAccount | All authenticated callers |
| enterprise_ledger_ | getTransactions | ledger:ListTransactions | All authenticated callers |
| enterprise_ledger_ | updateAccountStatus | ledger:UpdateAccount | All authenticated callers |
| enterprise_ledger_ | getCustomerPII | ledger:ReadPII | Requires `pii:read` scope |
| enterprise_ledger_ | getAuditLog | ledger:ReadAudit | Requires `audit:read` scope |
| employee_directory_ | listEmployees | employee:List | All authenticated callers |
| employee_directory_ | getEmployee | employee:Get | All authenticated callers |
| employee_directory_ | createEmployee | employee:Create | All authenticated callers |
| employee_directory_ | updateEmployee | employee:Update | All authenticated callers |
| employee_directory_ | deactivateEmployee | employee:Deactivate | All authenticated callers |
| employee_directory_ | getDirectReports | employee:List | All authenticated callers |
| employee_directory_ | listDepartments | department:List | All authenticated callers |

When AgentCore exposes them they're prefixed with the target name (`maverics-mcp___...`).

## Key files

| File | Purpose |
|------|---------|
| `orchestrator/oidc-provider/maverics.yaml` | OAuth authorization server config (includes `bedrock-agentcore` client) |
| `orchestrator/ai-identity-gateway/maverics.yaml` | MCP gateway config |
| `orchestrator/ai-identity-gateway/policies/*.rego` | OPA authorization policies |
| `cloudflared/config.yml.template` | Cloudflare Tunnel routing template |
| `aws/iam-policy.json` | Least-privilege IAM policy for the tutorial user |
| `aws/gateway-trust-policy.json` | Trust policy assumed by the AgentCore service |
| `aws/gateway-role-policy.json` | Permissions the gateway role needs (workload identity, model invoke, secrets, logs) |
| `scripts/aws-bootstrap.sh` | Creates the gateway IAM role |
| `scripts/agentcore-setup.sh` | Creates the OAuth provider, gateway, and target (2LO) |
| `scripts/agentcore-demo.sh` | Drives initialize / tools/list / tools/call against the AgentCore Gateway |
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
| `make agentcore-up` | Create the AgentCore Gateway and MCP target |
| `make agentcore-demo` | initialize / tools/list / tools/call against AgentCore |
| `make agentcore-down` | Tear down the AgentCore Gateway and target |

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `mkcert: command not found` | `brew install mkcert` (macOS) or see [mkcert docs](https://github.com/FiloSottile/mkcert#installation) |
| `cloudflared: command not found` | `brew install cloudflared` |
| Cloudflare DNS records not resolving | Wait a minute for propagation. Verify with `dig +short auth.<your-domain>` |
| AgentCore target stuck in `CREATING` then `FAILED` | Run `make agentcore-down` and check the failure reason: it usually means Maverics rejected the token. The most common cause is that the gateway's `expectedAudiences` does not include `https://auth.orchestrator.lab` (Maverics defaults `aud` to the issuer URL on Client Credentials grants when no `resource` parameter is sent) |
| `make agentcore-demo` returns `An internal error occurred` | The gateway has `--exception-level DEBUG` enabled by default; the response body includes a `_meta.debug` block with the real error. The most common cause is the gateway role missing `bedrock-agentcore:GetWorkloadAccessToken` |
| AWS access denied creating gateway | Verify the IAM user has the policy from `aws/iam-policy.json` attached |
| `model access denied` on agent invoke | First-time Anthropic users may need to fill in a use-case form via the console |

## Further reading

- [Strata MCP Provider](https://docs.strata.io/reference/orchestrator/applications/mcp-provider)
- [Strata Token Brokering (experimental)](https://docs.strata.io/reference/orchestrator/experimental/token-brokering)
- [Bedrock AgentCore Gateway: MCP server targets](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-target-MCPservers.html)
- [Bedrock AgentCore Gateway: Outbound auth](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-outbound-auth.html)
- [Bedrock AgentCore Gateway: Debugging](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-debugging.html)
- [MCP specification: Authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
- [RFC 9728: OAuth 2.0 Protected Resource Metadata](https://datatracker.ietf.org/doc/html/rfc9728)
- [RFC 8693: OAuth 2.0 Token Exchange](https://datatracker.ietf.org/doc/html/rfc8693)
