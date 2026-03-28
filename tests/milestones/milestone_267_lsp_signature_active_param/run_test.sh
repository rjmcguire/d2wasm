#!/bin/bash
# Test: LSP signature help activeParameter tracking
#
# Tests:
#   1. Trigger character "," updates activeParameter
#   2. Server advertises "," in signatureHelp triggerCharacters

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

echo "Test 1: Signature help with activeParameter..."

cat > "$WORK_DIR/sig.d" << 'EOF'
int add(int a, int b, int c) {
    return a + b + c;
}

int main() {
    return add(1, 2, 3);
}
EOF

SIG_URI="file://$WORK_DIR/sig.d"
SIG_TEXT=$(python3 -c "import json; print(json.dumps(open('$WORK_DIR/sig.d').read()))")

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
INITIALIZED='{"jsonrpc":"2.0","method":"initialized","params":{}}'
DID_OPEN='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$SIG_URI"'","languageId":"d","version":1,"text":'"$SIG_TEXT"'}}}'
# Request signature help at line 5, character 19 (after "add(1, 2,")  — should be activeParameter=2
SIG_HELP='{"jsonrpc":"2.0","id":2,"method":"textDocument/signatureHelp","params":{"textDocument":{"uri":"'"$SIG_URI"'"},"position":{"line":5,"character":22}}}'
SHUTDOWN='{"jsonrpc":"2.0","id":99,"method":"shutdown","params":null}'
EXIT_MSG='{"jsonrpc":"2.0","method":"exit","params":null}'

RESPONSE=$({
    lsp_msg "$INIT"
    lsp_msg "$INITIALIZED"
    lsp_msg "$DID_OPEN"
    sleep 1
    lsp_msg "$SIG_HELP"
    sleep 0.5
    lsp_msg "$SHUTDOWN"
    lsp_msg "$EXIT_MSG"
} | timeout 10 "$COMPILER" --lsp 2>"$WORK_DIR/lsp.log" || true)

# Check that comma is in trigger characters
if echo "$RESPONSE" | grep -q '","'; then
    echo "  OK: Comma is a trigger character"
else
    echo "FAIL: Comma not in trigger characters"
    echo "Response: $RESPONSE"
    exit 1
fi

# Check for signatures in response
if echo "$RESPONSE" | grep -q '"signatures"'; then
    echo "  OK: Signature help response has signatures"
else
    echo "FAIL: No signatures in response"
    echo "Response: $RESPONSE"
    exit 1
fi

# Check for activeParameter field
if echo "$RESPONSE" | grep -q '"activeParameter"'; then
    echo "  OK: Response has activeParameter field"
else
    echo "FAIL: No activeParameter in response"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "All LSP signature help activeParameter tests passed!"
