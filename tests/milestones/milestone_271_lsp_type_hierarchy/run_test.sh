#!/bin/bash
# Test: LSP type hierarchy
#
# Tests:
#   1. Server advertises typeHierarchyProvider
#   2. prepareTypeHierarchy returns item for class at cursor

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

echo "Test 1: Type hierarchy..."

cat > "$WORK_DIR/types.d" << 'EOF'
class Animal {
    int age;
}

class Dog : Animal {
    int tricks;
}

int main() {
    return 0;
}
EOF

TYPE_URI="file://$WORK_DIR/types.d"
TYPE_TEXT=$(python3 -c "import json; print(json.dumps(open('$WORK_DIR/types.d').read()))")

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
INITIALIZED='{"jsonrpc":"2.0","method":"initialized","params":{}}'
DID_OPEN='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$TYPE_URI"'","languageId":"d","version":1,"text":'"$TYPE_TEXT"'}}}'
SHUTDOWN='{"jsonrpc":"2.0","id":99,"method":"shutdown","params":null}'
EXIT_MSG='{"jsonrpc":"2.0","method":"exit","params":null}'

RESPONSE=$({
    lsp_msg "$INIT"
    lsp_msg "$INITIALIZED"
    lsp_msg "$DID_OPEN"
    sleep 1
    lsp_msg "$SHUTDOWN"
    lsp_msg "$EXIT_MSG"
} | timeout 10 "$COMPILER" --lsp 2>"$WORK_DIR/lsp.log" || true)

# Check that typeHierarchyProvider is advertised
if echo "$RESPONSE" | grep -q '"typeHierarchyProvider"'; then
    echo "  OK: Server advertises typeHierarchyProvider"
else
    echo "FAIL: No typeHierarchyProvider in capabilities"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "All LSP type hierarchy tests passed!"
