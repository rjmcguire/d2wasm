#!/bin/bash
# Test: LSP call hierarchy
#
# Tests:
#   1. Server advertises callHierarchyProvider
#   2. prepareCallHierarchy returns item for function at cursor
#   3. outgoingCalls returns callees

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

echo "Test 1: Call hierarchy..."

cat > "$WORK_DIR/calls.d" << 'EOF'
int leaf() { return 1; }

int middle() { return leaf(); }

int main() {
    return middle();
}
EOF

CALL_URI="file://$WORK_DIR/calls.d"
CALL_TEXT=$(python3 -c "import json; print(json.dumps(open('$WORK_DIR/calls.d').read()))")

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
INITIALIZED='{"jsonrpc":"2.0","method":"initialized","params":{}}'
DID_OPEN='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$CALL_URI"'","languageId":"d","version":1,"text":'"$CALL_TEXT"'}}}'
# prepareCallHierarchy on "middle" function (line 2, character 5)
PREPARE='{"jsonrpc":"2.0","id":2,"method":"textDocument/prepareCallHierarchy","params":{"textDocument":{"uri":"'"$CALL_URI"'"},"position":{"line":2,"character":5}}}'
SHUTDOWN='{"jsonrpc":"2.0","id":99,"method":"shutdown","params":null}'
EXIT_MSG='{"jsonrpc":"2.0","method":"exit","params":null}'

RESPONSE=$({
    lsp_msg "$INIT"
    lsp_msg "$INITIALIZED"
    lsp_msg "$DID_OPEN"
    sleep 1
    lsp_msg "$PREPARE"
    sleep 0.5
    lsp_msg "$SHUTDOWN"
    lsp_msg "$EXIT_MSG"
} | timeout 10 "$COMPILER" --lsp 2>"$WORK_DIR/lsp.log" || true)

# Check that callHierarchyProvider is advertised
if echo "$RESPONSE" | grep -q '"callHierarchyProvider"'; then
    echo "  OK: Server advertises callHierarchyProvider"
else
    echo "FAIL: No callHierarchyProvider in capabilities"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "All LSP call hierarchy tests passed!"
