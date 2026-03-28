#!/bin/bash
# Test: LSP incremental text sync
#
# Tests:
#   1. Server advertises textDocumentSync with change=2 (incremental)
#   2. Incremental didChange with range is accepted

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

echo "Test 1: Incremental text sync..."

cat > "$WORK_DIR/inc.d" << 'EOF'
int main() {
    return 0;
}
EOF

INC_URI="file://$WORK_DIR/inc.d"
INC_TEXT=$(python3 -c "import json; print(json.dumps(open('$WORK_DIR/inc.d').read()))")

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
INITIALIZED='{"jsonrpc":"2.0","method":"initialized","params":{}}'
DID_OPEN='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$INC_URI"'","languageId":"d","version":1,"text":'"$INC_TEXT"'}}}'
# Send incremental change: replace "0" with "42" on line 1
DID_CHANGE='{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"'"$INC_URI"'","version":2},"contentChanges":[{"range":{"start":{"line":1,"character":11},"end":{"line":1,"character":12}},"text":"42"}]}}'
DID_SAVE='{"jsonrpc":"2.0","method":"textDocument/didSave","params":{"textDocument":{"uri":"'"$INC_URI"'"}}}'
SHUTDOWN='{"jsonrpc":"2.0","id":99,"method":"shutdown","params":null}'
EXIT_MSG='{"jsonrpc":"2.0","method":"exit","params":null}'

RESPONSE=$({
    lsp_msg "$INIT"
    lsp_msg "$INITIALIZED"
    lsp_msg "$DID_OPEN"
    sleep 1
    lsp_msg "$DID_CHANGE"
    sleep 0.5
    lsp_msg "$DID_SAVE"
    sleep 0.5
    lsp_msg "$SHUTDOWN"
    lsp_msg "$EXIT_MSG"
} | timeout 10 "$COMPILER" --lsp 2>"$WORK_DIR/lsp.log" || true)

# Check that textDocumentSync advertises incremental mode
if echo "$RESPONSE" | grep -q '"change":2'; then
    echo "  OK: Server advertises incremental sync (change=2)"
else
    echo "FAIL: Server does not advertise incremental sync"
    echo "Response: $RESPONSE"
    exit 1
fi

# Server should not crash — if we got the shutdown response, it worked
if echo "$RESPONSE" | grep -q '"id":99'; then
    echo "  OK: Server handled incremental change without crashing"
else
    echo "FAIL: Server did not respond to shutdown after incremental change"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "All LSP incremental sync tests passed!"
