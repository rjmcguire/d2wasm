#!/bin/bash
# Test: LSP server JSON-RPC transport
#
# Tests:
#   1. Send initialize request, verify initialize response with capabilities
#   2. Send initialized notification
#   3. Send shutdown request, verify response
#   4. Send exit notification

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

###############################################################################
# Test 1: Initialize + Shutdown handshake
###############################################################################
echo "Test 1: LSP initialize/shutdown..."

INIT_REQ='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
INIT_NOTIF='{"jsonrpc":"2.0","method":"initialized","params":{}}'
SHUTDOWN_REQ='{"jsonrpc":"2.0","id":2,"method":"shutdown","params":null}'
EXIT_NOTIF='{"jsonrpc":"2.0","method":"exit","params":null}'

# Write all messages to a file, then pipe to LSP server
{
    lsp_msg "$INIT_REQ"
    lsp_msg "$INIT_NOTIF"
    lsp_msg "$SHUTDOWN_REQ"
    lsp_msg "$EXIT_NOTIF"
} > "$WORK_DIR/lsp_input.bin"

RESPONSE=$(timeout 5 "$COMPILER" --lsp < "$WORK_DIR/lsp_input.bin" 2>"$WORK_DIR/lsp.log" || true)

# Check for initialize response
if echo "$RESPONSE" | grep -q '"definitionProvider":true'; then
    echo "  OK: Initialize response has definitionProvider"
else
    echo "FAIL: Missing definitionProvider in response"
    echo "Response: $RESPONSE"
    cat "$WORK_DIR/lsp.log"
    exit 1
fi

if echo "$RESPONSE" | grep -q '"hoverProvider":true'; then
    echo "  OK: Initialize response has hoverProvider"
else
    echo "FAIL: Missing hoverProvider in response"
    exit 1
fi

if echo "$RESPONSE" | grep -q '"d2wasm-lsp"'; then
    echo "  OK: Server identifies as d2wasm-lsp"
else
    echo "FAIL: Missing server name"
    exit 1
fi

# Check for shutdown response (result: null)
if echo "$RESPONSE" | grep -q '"id":2'; then
    echo "  OK: Shutdown response received"
else
    echo "FAIL: No shutdown response"
    exit 1
fi

echo "All LSP transport tests passed!"
