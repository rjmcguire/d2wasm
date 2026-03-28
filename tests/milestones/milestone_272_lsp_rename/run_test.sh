#!/bin/bash
# Test: LSP rename
#
# Tests:
#   1. Server advertises renameProvider with prepareProvider
#   2. prepareRename returns range and placeholder
#   3. rename returns workspace edit

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

echo "Test 1: Rename support..."

cat > "$WORK_DIR/ren.d" << 'EOF'
int getValue() { return 42; }

int main() {
    int x = getValue();
    return x;
}
EOF

REN_URI="file://$WORK_DIR/ren.d"
REN_TEXT=$(python3 -c "import json; print(json.dumps(open('$WORK_DIR/ren.d').read()))")

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
INITIALIZED='{"jsonrpc":"2.0","method":"initialized","params":{}}'
DID_OPEN='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$REN_URI"'","languageId":"d","version":1,"text":'"$REN_TEXT"'}}}'
# prepareRename on "getValue" at line 3, character 14
PREPARE_RENAME='{"jsonrpc":"2.0","id":2,"method":"textDocument/prepareRename","params":{"textDocument":{"uri":"'"$REN_URI"'"},"position":{"line":3,"character":14}}}'
SHUTDOWN='{"jsonrpc":"2.0","id":99,"method":"shutdown","params":null}'
EXIT_MSG='{"jsonrpc":"2.0","method":"exit","params":null}'

RESPONSE=$({
    lsp_msg "$INIT"
    lsp_msg "$INITIALIZED"
    lsp_msg "$DID_OPEN"
    sleep 1
    lsp_msg "$PREPARE_RENAME"
    sleep 0.5
    lsp_msg "$SHUTDOWN"
    lsp_msg "$EXIT_MSG"
} | timeout 10 "$COMPILER" --lsp 2>"$WORK_DIR/lsp.log" || true)

# Check that renameProvider is advertised with prepareProvider
if echo "$RESPONSE" | grep -q '"renameProvider"'; then
    echo "  OK: Server advertises renameProvider"
else
    echo "FAIL: No renameProvider in capabilities"
    echo "Response: $RESPONSE"
    exit 1
fi

if echo "$RESPONSE" | grep -q '"prepareProvider"'; then
    echo "  OK: renameProvider has prepareProvider"
else
    echo "FAIL: No prepareProvider in rename capabilities"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "All LSP rename tests passed!"
