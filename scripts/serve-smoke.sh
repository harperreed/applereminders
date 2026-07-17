#!/usr/bin/env bash
# ABOUTME: Live smoke test for the network server REST and MCP surfaces over tailscale.
# ABOUTME: TCC-dependent, best effort: runs a create/edit/complete/delete cycle via curl.

set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    echo "usage: $0 [base-url]" >&2
    echo "  base-url          target a running server; omit to start .build/debug/reminders serve" >&2
    echo "  REMINDERS_TOKEN   overrides the token read from ~/.config/reminders-mcp/token" >&2
    exit "${1:-2}"
}

case "${1:-}" in
    -h|--help) usage 0 ;;
esac
if [[ $# -gt 1 ]]; then
    usage
fi

if [[ -n "${REMINDERS_TOKEN:-}" ]]; then
    TOKEN="$REMINDERS_TOKEN"
else
    TOKEN_FILE="$HOME/.config/reminders-mcp/token"
    if [[ ! -r "$TOKEN_FILE" ]]; then
        echo "serve-smoke: no readable token at $TOKEN_FILE; run 'reminders serve --generate-token'" >&2
        exit 1
    fi
    TOKEN=$(tr -d '\r\n' < "$TOKEN_FILE")
fi
AUTH=(-H "Authorization: Bearer $TOKEN")
SERVER_PID=""
ITEM_URL=""

cleanup() {
    if [[ -n "$ITEM_URL" ]]; then
        curl -fsS "${AUTH[@]}" -X DELETE "$ITEM_URL" >/dev/null 2>&1 || true
    fi
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [[ -n "${1:-}" ]]; then
    BASE_URL="${1%/}"
else
    TAILSCALE_IP=$(ifconfig | awk '
        /inet 100\./ {
            split($2, octets, ".")
            if (octets[2] >= 64 && octets[2] <= 127) {
                print $2
                exit
            }
        }
    ')
    if [[ -z "$TAILSCALE_IP" ]]; then
        echo "serve-smoke: no tailscale interface found" >&2
        exit 1
    fi
    BASE_URL="http://$TAILSCALE_IP:7364"
    swift build >/dev/null
    .build/debug/reminders serve &
    SERVER_PID=$!
    READY=false
    for _ in $(seq 1 20); do
        if curl -fsS "${AUTH[@]}" "$BASE_URL/api/lists" >/dev/null 2>&1; then
            READY=true
            break
        fi
        sleep 0.5
    done
    if [[ "$READY" != true ]]; then
        echo "serve-smoke: server did not become ready at $BASE_URL" >&2
        exit 1
    fi
fi

echo "== lists"
LISTS=$(curl -fsS "${AUTH[@]}" "$BASE_URL/api/lists")
echo "$LISTS"

LIST=$(jq -er '.[0].title | select(type == "string" and length > 0)' <<< "$LISTS")
echo "== using list: $LIST"

echo "== create"
TITLE="serve-smoke $(date +%s)"
CREATE_BODY=$(jq -cn --arg list "$LIST" --arg title "$TITLE" \
    '{list: $list, title: $title, due_date: "tomorrow"}')
ITEM=$(curl -fsS "${AUTH[@]}" -X POST "$BASE_URL/api/reminders" \
    -H 'Content-Type: application/json' \
    -d "$CREATE_BODY")
echo "$ITEM"
ID=$(jq -er '.id | select(type == "string" and length > 0)' <<< "$ITEM")
ENCODED_ID=$(jq -rn --arg value "$ID" '$value | @uri')
ITEM_URL="$BASE_URL/api/reminders/$ENCODED_ID"

echo "== patch (rename, clear due date)"
curl -fsS "${AUTH[@]}" -X PATCH "$ITEM_URL" \
    -H 'Content-Type: application/json' \
    -d '{"title": "serve-smoke edited", "due_date": null}'
echo

echo "== complete"
curl -fsS "${AUTH[@]}" -X POST "$ITEM_URL/complete"
echo

echo "== uncomplete"
curl -fsS "${AUTH[@]}" -X POST "$ITEM_URL/uncomplete"
echo

echo "== delete"
curl -fsS "${AUTH[@]}" -X DELETE "$ITEM_URL"
ITEM_URL=""
echo

echo "== auth check (expect 401)"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/api/lists")
if [[ "$STATUS" != "401" ]]; then
    echo "serve-smoke: expected 401 without token, got $STATUS" >&2
    exit 1
fi

echo "== MCP initialize"
MCP_RESPONSE=$(curl -fsS "${AUTH[@]}" -X POST "$BASE_URL/mcp" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}')
echo "$MCP_RESPONSE"
jq -e '.id == 1 and (.result.protocolVersion | type == "string")' >/dev/null <<< "$MCP_RESPONSE"

echo "serve-smoke: PASS"
