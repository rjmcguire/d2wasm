#!/bin/bash
# Parity test: LSP server initialize/shutdown with diagnostics
#
# Args: $1 = CTFE backend (wasm|native), $2 = compiler path

set -e

BACKEND="${1:?usage: run_test.sh <backend> <compiler>}"
COMPILER="${2:?usage: run_test.sh <backend> <compiler>}"
WORK_DIR=$(mktemp -d)

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

lsp_msg() {
    local body="$1"
    local len=${#body}
    printf "Content-Length: %d\r\n\r\n%s" "$len" "$body"
}

# Create a valid file for diagnostics
cat > "$WORK_DIR/good.d" << 'EOF'
int main() { return 42; }
EOF

GOOD_URI="file://$WORK_DIR/good.d"
GOOD_TEXT=$(python3 -c "import json; print(json.dumps(open('$WORK_DIR/good.d').read()))")

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
INITIALIZED='{"jsonrpc":"2.0","method":"initialized","params":{}}'
DID_OPEN='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$GOOD_URI"'","languageId":"d","version":1,"text":'"$GOOD_TEXT"'}}}'
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

if ! echo "$RESPONSE" | grep -q '"definitionProvider":true'; then
    echo "FAIL: Missing definitionProvider in response"
    exit 1
fi

if ! echo "$RESPONSE" | grep -q '"d2wasm-lsp"'; then
    echo "FAIL: Missing server name"
    exit 1
fi

if ! echo "$RESPONSE" | grep -q '"id":99'; then
    echo "FAIL: No shutdown response"
    exit 1
fi
