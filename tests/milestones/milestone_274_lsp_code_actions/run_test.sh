#!/bin/bash
# Test: LSP code actions
#
# Tests:
#   1. Server advertises codeActionProvider
#   2. Code action request is handled (doesn't crash)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPILER="$SCRIPT_DIR/../../../d2wasm"
WORK_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

lsp_msg() {
    local body="$1"
    local len=${#body}
    printf "Content-Length: %d\r\n\r\n%s" "$len" "$body"
}

echo "Test 1: Code actions..."

cat > "$WORK_DIR/action.d" << 'EOF'
int getValue() { return 42; }

int main() {
    return getValue();
}
EOF

ACT_URI="file://$WORK_DIR/action.d"
ACT_TEXT=$(python3 -c "import json; print(json.dumps(open('$WORK_DIR/action.d').read()))")

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
INITIALIZED='{"jsonrpc":"2.0","method":"initialized","params":{}}'
DID_OPEN='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$ACT_URI"'","languageId":"d","version":1,"text":'"$ACT_TEXT"'}}}'
# Request code actions at line 3
CODE_ACTION='{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"'"$ACT_URI"'"},"range":{"start":{"line":3,"character":0},"end":{"line":3,"character":20}},"context":{"diagnostics":[]}}}'
SHUTDOWN='{"jsonrpc":"2.0","id":99,"method":"shutdown","params":null}'
EXIT_MSG='{"jsonrpc":"2.0","method":"exit","params":null}'

RESPONSE=$({
    lsp_msg "$INIT"
    lsp_msg "$INITIALIZED"
    lsp_msg "$DID_OPEN"
    sleep 1
    lsp_msg "$CODE_ACTION"
    sleep 0.5
    lsp_msg "$SHUTDOWN"
    lsp_msg "$EXIT_MSG"
} | timeout 10 "$COMPILER" --lsp 2>"$WORK_DIR/lsp.log" || true)

# Check that codeActionProvider is advertised
if echo "$RESPONSE" | grep -q '"codeActionProvider"'; then
    echo "  OK: Server advertises codeActionProvider"
else
    echo "FAIL: No codeActionProvider in capabilities"
    echo "Response: $RESPONSE"
    exit 1
fi

# Server should not crash — check shutdown response
if echo "$RESPONSE" | grep -q '"id":99'; then
    echo "  OK: Server handled code action request without crashing"
else
    echo "FAIL: Server did not respond to shutdown after code action"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "All LSP code action tests passed!"
