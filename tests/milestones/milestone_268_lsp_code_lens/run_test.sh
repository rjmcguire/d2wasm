#!/bin/bash
# Test: LSP code lens reference counts
#
# Tests:
#   1. Server advertises codeLensProvider
#   2. Code lens returns reference counts for declarations

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

echo "Test 1: Code lens reference counts..."

cat > "$WORK_DIR/lens.d" << 'EOF'
int helper() { return 42; }

int main() {
    return helper();
}
EOF

LENS_URI="file://$WORK_DIR/lens.d"
LENS_TEXT=$(python3 -c "import json; print(json.dumps(open('$WORK_DIR/lens.d').read()))")

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
INITIALIZED='{"jsonrpc":"2.0","method":"initialized","params":{}}'
DID_OPEN='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$LENS_URI"'","languageId":"d","version":1,"text":'"$LENS_TEXT"'}}}'
CODE_LENS='{"jsonrpc":"2.0","id":2,"method":"textDocument/codeLens","params":{"textDocument":{"uri":"'"$LENS_URI"'"}}}'
SHUTDOWN='{"jsonrpc":"2.0","id":99,"method":"shutdown","params":null}'
EXIT_MSG='{"jsonrpc":"2.0","method":"exit","params":null}'

RESPONSE=$({
    lsp_msg "$INIT"
    lsp_msg "$INITIALIZED"
    lsp_msg "$DID_OPEN"
    sleep 1
    lsp_msg "$CODE_LENS"
    sleep 0.5
    lsp_msg "$SHUTDOWN"
    lsp_msg "$EXIT_MSG"
} | timeout 10 "$COMPILER" --lsp 2>"$WORK_DIR/lsp.log" || true)

# Check that codeLensProvider is advertised
if echo "$RESPONSE" | grep -q '"codeLensProvider"'; then
    echo "  OK: Server advertises codeLensProvider"
else
    echo "FAIL: No codeLensProvider in capabilities"
    echo "Response: $RESPONSE"
    exit 1
fi

# Check for "reference" in code lens command titles
if echo "$RESPONSE" | grep -q 'reference'; then
    echo "  OK: Code lens shows reference counts"
else
    echo "FAIL: No reference count in code lens"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "All LSP code lens tests passed!"
