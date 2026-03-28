#!/bin/bash
# Test: LSP semantic tokens
#
# Tests:
#   1. Server advertises semanticTokensProvider with legend
#   2. Semantic tokens full request returns data array

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

echo "Test 1: Semantic tokens..."

cat > "$WORK_DIR/tokens.d" << 'EOF'
struct Point {
    int x;
    int y;
}

int getValue() { return 10; }

int main() {
    int a = getValue();
    return a;
}
EOF

TOK_URI="file://$WORK_DIR/tokens.d"
TOK_TEXT=$(python3 -c "import json; print(json.dumps(open('$WORK_DIR/tokens.d').read()))")

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
INITIALIZED='{"jsonrpc":"2.0","method":"initialized","params":{}}'
DID_OPEN='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$TOK_URI"'","languageId":"d","version":1,"text":'"$TOK_TEXT"'}}}'
SEM_TOKENS='{"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":"'"$TOK_URI"'"}}}'
SHUTDOWN='{"jsonrpc":"2.0","id":99,"method":"shutdown","params":null}'
EXIT_MSG='{"jsonrpc":"2.0","method":"exit","params":null}'

RESPONSE=$({
    lsp_msg "$INIT"
    lsp_msg "$INITIALIZED"
    lsp_msg "$DID_OPEN"
    sleep 1
    lsp_msg "$SEM_TOKENS"
    sleep 0.5
    lsp_msg "$SHUTDOWN"
    lsp_msg "$EXIT_MSG"
} | timeout 10 "$COMPILER" --lsp 2>"$WORK_DIR/lsp.log" || true)

# Check that semanticTokensProvider is advertised with a legend
if echo "$RESPONSE" | grep -q '"semanticTokensProvider"'; then
    echo "  OK: Server advertises semanticTokensProvider"
else
    echo "FAIL: No semanticTokensProvider in capabilities"
    echo "Response: $RESPONSE"
    exit 1
fi

if echo "$RESPONSE" | grep -q '"tokenTypes"'; then
    echo "  OK: Legend has tokenTypes"
else
    echo "FAIL: No tokenTypes in legend"
    echo "Response: $RESPONSE"
    exit 1
fi

# Check that semantic tokens response has data array
if echo "$RESPONSE" | grep -q '"data"'; then
    echo "  OK: Semantic tokens response has data"
else
    echo "FAIL: No data in semantic tokens response"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "All LSP semantic tokens tests passed!"
