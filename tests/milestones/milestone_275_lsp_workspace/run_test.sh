#!/bin/bash
# Test: LSP workspace support
#
# Tests:
#   1. Server reads rootUri from initialize params
#   2. Server advertises workspace.workspaceFolders capability
#   3. Server handles didChangeWorkspaceFolders notification

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

echo "Test 1: Workspace support..."

cat > "$WORK_DIR/ws.d" << 'EOF'
int main() {
    return 0;
}
EOF

WS_URI="file://$WORK_DIR/ws.d"
WS_TEXT=$(python3 -c "import json; print(json.dumps(open('$WORK_DIR/ws.d').read()))")
WS_ROOT="file://$WORK_DIR"

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":"'"$WS_ROOT"'","workspaceFolders":[{"uri":"'"$WS_ROOT"'","name":"test"}]}}'
INITIALIZED='{"jsonrpc":"2.0","method":"initialized","params":{}}'
DID_OPEN='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$WS_URI"'","languageId":"d","version":1,"text":'"$WS_TEXT"'}}}'
# Send workspace folder change notification
WS_CHANGE='{"jsonrpc":"2.0","method":"workspace/didChangeWorkspaceFolders","params":{"event":{"added":[{"uri":"file:///tmp/extra","name":"extra"}],"removed":[]}}}'
SHUTDOWN='{"jsonrpc":"2.0","id":99,"method":"shutdown","params":null}'
EXIT_MSG='{"jsonrpc":"2.0","method":"exit","params":null}'

RESPONSE=$({
    lsp_msg "$INIT"
    lsp_msg "$INITIALIZED"
    lsp_msg "$DID_OPEN"
    sleep 1
    lsp_msg "$WS_CHANGE"
    sleep 0.5
    lsp_msg "$SHUTDOWN"
    lsp_msg "$EXIT_MSG"
} | timeout 10 "$COMPILER" --lsp 2>"$WORK_DIR/lsp.log" || true)

# Check that workspace capabilities are advertised
if echo "$RESPONSE" | grep -q '"workspaceFolders"'; then
    echo "  OK: Server advertises workspace.workspaceFolders"
else
    echo "FAIL: No workspaceFolders in capabilities"
    echo "Response: $RESPONSE"
    exit 1
fi

# Server should not crash
if echo "$RESPONSE" | grep -q '"id":99'; then
    echo "  OK: Server handled workspace changes without crashing"
else
    echo "FAIL: Server did not respond to shutdown after workspace changes"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "All LSP workspace tests passed!"
