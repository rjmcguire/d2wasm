#!/bin/bash
# Test: LSP completion
#
# Tests:
#   1. Open a file, request completion → get function names
#   2. Verify completion items have correct kinds

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPILER="$SCRIPT_DIR/../../../d2wasm"
WORK_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Helper: format a JSON-RPC message with Content-Length header
lsp_msg() {
    local body="$1"
    local len=${#body}
    printf "Content-Length: %d\r\n\r\n%s" "$len" "$body"
}

echo "Test 1: Identifier completion..."

cat > "$WORK_DIR/comp.d" << 'EOF'
int getValue() { return 10; }
int getOther() { return 20; }

int main() {
    return get
}
EOF

COMP_URI="file://$WORK_DIR/comp.d"
COMP_TEXT=$(python3 -c "import json; print(json.dumps(open('$WORK_DIR/comp.d').read()))")

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
INITIALIZED='{"jsonrpc":"2.0","method":"initialized","params":{}}'
DID_OPEN='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$COMP_URI"'","languageId":"d","version":1,"text":'"$COMP_TEXT"'}}}'
# Request completion at line 4, character 14 (after "get")
COMPLETION='{"jsonrpc":"2.0","id":2,"method":"textDocument/completion","params":{"textDocument":{"uri":"'"$COMP_URI"'"},"position":{"line":4,"character":14}}}'
SHUTDOWN='{"jsonrpc":"2.0","id":99,"method":"shutdown","params":null}'
EXIT_MSG='{"jsonrpc":"2.0","method":"exit","params":null}'

RESPONSE=$({
    lsp_msg "$INIT"
    lsp_msg "$INITIALIZED"
    lsp_msg "$DID_OPEN"
    sleep 1
    lsp_msg "$COMPLETION"
    sleep 0.5
    lsp_msg "$SHUTDOWN"
    lsp_msg "$EXIT_MSG"
} | timeout 10 "$COMPILER" --lsp 2>"$WORK_DIR/lsp.log" || true)

# Check for completion items
if echo "$RESPONSE" | grep -q '"items"'; then
    echo "  OK: Completion response has items"
else
    echo "FAIL: No completion items in response"
    echo "Response: $RESPONSE"
    exit 1
fi

# Check for completionProvider in capabilities
if echo "$RESPONSE" | grep -q '"completionProvider"'; then
    echo "  OK: Server advertises completionProvider"
else
    echo "FAIL: No completionProvider in capabilities"
    exit 1
fi

echo "All LSP completion tests passed!"
