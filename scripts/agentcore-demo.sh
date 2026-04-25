#!/usr/bin/env bash
# Smoke-test the AgentCore Gateway end to end:
#   1. Initialize an MCP session against the AgentCore Gateway URL.
#   2. List the tools AgentCore discovered from your Maverics MCP server.
#   3. Invoke `enterprise_ledger_listAccounts` and print the result.
#
# The full chain exercised: Bedrock client -> AgentCore Gateway -> Cloudflare
# Tunnel -> Maverics MCP gateway -> OPA inbound policy -> RFC 8693 token
# exchange -> Enterprise Ledger backend.
set -euo pipefail

: "${AGENTCORE_GATEWAY_URL:?AGENTCORE_GATEWAY_URL must be set (printed by agentcore-setup.sh)}"
: "${AGENTCORE_TARGET_NAME:=maverics-mcp}"
: "${TOOL_NAME:=${AGENTCORE_TARGET_NAME}___enterprise_ledger_listAccounts}"

URL="${AGENTCORE_GATEWAY_URL}"

echo "==> 1. initialize"
SESSION=$(curl -s -i -X POST "${URL}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"agentcore-demo","version":"1"}},"id":1}' \
  --max-time 20 \
  | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' | tr -d '\r\n')
echo "    session: ${SESSION}"

echo "==> 2. notifications/initialized"
curl -sS -X POST "${URL}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: ${SESSION}" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  --max-time 10 >/dev/null

echo "==> 3. tools/list"
curl -sS -X POST "${URL}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: ${SESSION}" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":2}' \
  --max-time 20 \
  | python3 -c "import sys,json,re;t=sys.stdin.read();m=re.search(r'\{.*\}',t,re.S);d=json.loads(m.group(0));print('\n'.join('  - '+t['name'] for t in d['result']['tools']))"

echo "==> 4. tools/call ${TOOL_NAME}"
curl -sS -X POST "${URL}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: ${SESSION}" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"${TOOL_NAME}\",\"arguments\":{}},\"id\":3}" \
  --max-time 30 \
  | python3 -c "import sys,json,re;t=sys.stdin.read();m=re.search(r'\{.*\}',t,re.S);d=json.loads(m.group(0));r=d.get('result',{});isErr=r.get('isError');content=r.get('content',[{}])[0].get('text','');print('isError:',isErr);print('---');print(content[:1500])"
