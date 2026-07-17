#!/usr/bin/env bash
# ABOUTME: End-to-end smoke test proving a long-running MCP server sees reminders
# ABOUTME: added by another process (EKEventStoreChanged freshness). Needs TCC grant.
#
# Usage: bash scripts/mcp-freshness-smoke.sh
# Exit 0 with "PASS" when the server's second fetch contains the probe reminder.

set -euo pipefail
cd "$(dirname "$0")/.."

BIN=.build/debug/reminders
LIST="MCP Smoke Test"

swift build >/dev/null

# Ensure the target list exists (idempotent; ignore "already exists" style failures).
$BIN new-list "$LIST" >/dev/null 2>&1 || true

FIFO=$(mktemp -u /tmp/mcp-fifo.XXXXXX)
OUT=$(mktemp /tmp/mcp-out.XXXXXX)
mkfifo "$FIFO"

$BIN --mcp < "$FIFO" > "$OUT" 2>/dev/null &
SERVER=$!
exec 3> "$FIFO"

echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"show_reminders","arguments":{"list":"MCP Smoke Test"}}}' >&3
sleep 2

PROBE="Freshness probe $$"
$BIN add "$LIST" $PROBE >/dev/null
sleep 2

echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"show_reminders","arguments":{"list":"MCP Smoke Test"}}}' >&3
sleep 2

exec 3>&-
wait "$SERVER" 2>/dev/null || true

if grep -q "Freshness probe $$" "$OUT"; then
    echo "PASS: running MCP server saw the externally added reminder"
    STATUS=0
else
    echo "FAIL: probe reminder not visible to the running server; server output:"
    cat "$OUT"
    STATUS=1
fi

rm -f "$FIFO" "$OUT"
exit $STATUS
