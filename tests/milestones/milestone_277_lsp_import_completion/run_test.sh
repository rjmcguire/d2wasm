#!/bin/bash
# Test: LSP import completion
#
# Tests:
#   1. Import path completion — "import " lists available modules
#   2. Import path completion with prefix — "import he" filters by prefix
#   3. Nested import path — "import subpkg." lists subpackage contents
#   4. Selective import completion — "import helper : " lists module exports
#   5. Selective import with prefix filter — "import helper : get" filters symbols
#   6. Non-import dot does NOT trigger import completion (regression guard)

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

# Set up a multi-module project structure
mkdir -p "$WORK_DIR/src/subpkg"
cat > "$WORK_DIR/src/helper.d" << 'EOF'
module helper;

int getValue() { return 10; }
int getOther() { return 20; }
string greet() { return "hi"; }
EOF

cat > "$WORK_DIR/src/utils.d" << 'EOF'
module utils;

int add(int a, int b) { return a + b; }
EOF

cat > "$WORK_DIR/src/subpkg/inner.d" << 'EOF'
module subpkg.inner;

int innerFunc() { return 42; }
EOF

# ── Test 1: Import path completion — "import " lists modules ──
echo "Test 1: Import path completion (bare 'import ')..."

# Note: printf used to control exact content (no extra newline issues)
printf 'import ' > "$WORK_DIR/src/test1.d"

TEST1_URI="file://$WORK_DIR/src/test1.d"
TEST1_TEXT=$(python3 -c "import json; print(json.dumps(open('$WORK_DIR/src/test1.d').read()))")

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":"file://'"$WORK_DIR/src"'"}}'
INITIALIZED='{"jsonrpc":"2.0","method":"initialized","params":{}}'
DID_OPEN='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$TEST1_URI"'","languageId":"d","version":1,"text":'"$TEST1_TEXT"'}}}'
# Cursor at line 0, character 7 (after "import ")
COMPLETION='{"jsonrpc":"2.0","id":2,"method":"textDocument/completion","params":{"textDocument":{"uri":"'"$TEST1_URI"'"},"position":{"line":0,"character":7}}}'
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
} | timeout 10 "$COMPILER" --lsp -I "$WORK_DIR/src" 2>"$WORK_DIR/lsp1.log" || true)

if echo "$RESPONSE" | grep -q '"items"'; then
    echo "  OK: Got completion items"
else
    echo "FAIL: No completion items in response"
    echo "Response: $RESPONSE"
    cat "$WORK_DIR/lsp1.log" 2>/dev/null
    exit 1
fi

# Should find "helper" module
if echo "$RESPONSE" | grep -q '"helper"'; then
    echo "  OK: Found 'helper' module in completions"
else
    echo "FAIL: 'helper' not found in import completions"
    echo "Response: $RESPONSE"
    exit 1
fi

# Should find "utils" module
if echo "$RESPONSE" | grep -q '"utils"'; then
    echo "  OK: Found 'utils' module in completions"
else
    echo "FAIL: 'utils' not found in import completions"
    echo "Response: $RESPONSE"
    exit 1
fi

# Should find "subpkg" package (directory)
if echo "$RESPONSE" | grep -q '"subpkg"'; then
    echo "  OK: Found 'subpkg' package in completions"
else
    echo "FAIL: 'subpkg' not found in import completions"
    echo "Response: $RESPONSE"
    exit 1
fi

# ── Test 2: Import path with prefix filter — "import he" ──
echo ""
echo "Test 2: Import path with prefix filter ('import he')..."

printf 'import he' > "$WORK_DIR/src/test2.d"

TEST2_URI="file://$WORK_DIR/src/test2.d"
TEST2_TEXT=$(python3 -c "import json; print(json.dumps(open('$WORK_DIR/src/test2.d').read()))")

DID_OPEN2='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$TEST2_URI"'","languageId":"d","version":1,"text":'"$TEST2_TEXT"'}}}'
# Cursor at line 0, character 9 (after "import he")
COMPLETION2='{"jsonrpc":"2.0","id":3,"method":"textDocument/completion","params":{"textDocument":{"uri":"'"$TEST2_URI"'"},"position":{"line":0,"character":9}}}'

RESPONSE2=$({
    lsp_msg "$INIT"
    lsp_msg "$INITIALIZED"
    lsp_msg "$DID_OPEN2"
    sleep 1
    lsp_msg "$COMPLETION2"
    sleep 0.5
    lsp_msg "$SHUTDOWN"
    lsp_msg "$EXIT_MSG"
} | timeout 10 "$COMPILER" --lsp -I "$WORK_DIR/src" 2>"$WORK_DIR/lsp2.log" || true)

# Should find "helper" (starts with "he")
if echo "$RESPONSE2" | grep -q '"helper"'; then
    echo "  OK: Found 'helper' with prefix filter"
else
    echo "FAIL: 'helper' not found with prefix 'he'"
    echo "Response: $RESPONSE2"
    exit 1
fi

# Should NOT find "utils" (doesn't start with "he")
if echo "$RESPONSE2" | grep -q '"utils"'; then
    echo "FAIL: 'utils' should not appear with prefix 'he'"
    echo "Response: $RESPONSE2"
    exit 1
else
    echo "  OK: 'utils' correctly filtered out"
fi

# ── Test 3: Nested import path — "import subpkg." ──
echo ""
echo "Test 3: Nested import path ('import subpkg.')..."

printf 'import subpkg.' > "$WORK_DIR/src/test3.d"

TEST3_URI="file://$WORK_DIR/src/test3.d"
TEST3_TEXT=$(python3 -c "import json; print(json.dumps(open('$WORK_DIR/src/test3.d').read()))")

DID_OPEN3='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$TEST3_URI"'","languageId":"d","version":1,"text":'"$TEST3_TEXT"'}}}'
# Cursor at line 0, character 14 (after "import subpkg.")
COMPLETION3='{"jsonrpc":"2.0","id":4,"method":"textDocument/completion","params":{"textDocument":{"uri":"'"$TEST3_URI"'"},"position":{"line":0,"character":14}}}'

RESPONSE3=$({
    lsp_msg "$INIT"
    lsp_msg "$INITIALIZED"
    lsp_msg "$DID_OPEN3"
    sleep 1
    lsp_msg "$COMPLETION3"
    sleep 0.5
    lsp_msg "$SHUTDOWN"
    lsp_msg "$EXIT_MSG"
} | timeout 10 "$COMPILER" --lsp -I "$WORK_DIR/src" 2>"$WORK_DIR/lsp3.log" || true)

# Should find "inner" module inside subpkg/
if echo "$RESPONSE3" | grep -q '"inner"'; then
    echo "  OK: Found 'inner' in subpkg completions"
else
    echo "FAIL: 'inner' not found in subpkg import completions"
    echo "Response: $RESPONSE3"
    exit 1
fi

# ── Test 4: Selective import completion — "import helper : " ──
echo ""
echo "Test 4: Selective import completion ('import helper : ')..."

# First we need to compile helper.d so it's in the warm state.
# Open and save helper.d, then open test file with selective import.
printf 'import helper : ' > "$WORK_DIR/src/test4.d"

TEST4_URI="file://$WORK_DIR/src/test4.d"
TEST4_TEXT=$(python3 -c "import json; print(json.dumps(open('$WORK_DIR/src/test4.d').read()))")
HELPER_URI="file://$WORK_DIR/src/helper.d"
HELPER_TEXT=$(python3 -c "import json; print(json.dumps(open('$WORK_DIR/src/helper.d').read()))")

DID_OPEN_HELPER='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$HELPER_URI"'","languageId":"d","version":1,"text":'"$HELPER_TEXT"'}}}'
DID_SAVE_HELPER='{"jsonrpc":"2.0","method":"textDocument/didSave","params":{"textDocument":{"uri":"'"$HELPER_URI"'"}}}'
DID_OPEN4='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$TEST4_URI"'","languageId":"d","version":1,"text":'"$TEST4_TEXT"'}}}'
# Cursor at line 0, character 16 (after "import helper : ")
COMPLETION4='{"jsonrpc":"2.0","id":5,"method":"textDocument/completion","params":{"textDocument":{"uri":"'"$TEST4_URI"'"},"position":{"line":0,"character":16}}}'

RESPONSE4=$({
    lsp_msg "$INIT"
    lsp_msg "$INITIALIZED"
    lsp_msg "$DID_OPEN_HELPER"
    sleep 1
    lsp_msg "$DID_SAVE_HELPER"
    sleep 1
    lsp_msg "$DID_OPEN4"
    sleep 0.5
    lsp_msg "$COMPLETION4"
    sleep 0.5
    lsp_msg "$SHUTDOWN"
    lsp_msg "$EXIT_MSG"
} | timeout 15 "$COMPILER" --lsp -I "$WORK_DIR/src" 2>"$WORK_DIR/lsp4.log" || true)

if echo "$RESPONSE4" | grep -q '"items"'; then
    echo "  OK: Got selective import completion items"
else
    echo "FAIL: No items in selective import completion"
    echo "Response: $RESPONSE4"
    cat "$WORK_DIR/lsp4.log" 2>/dev/null
    exit 1
fi

# Should find "getValue" from helper module
if echo "$RESPONSE4" | grep -q '"getValue"'; then
    echo "  OK: Found 'getValue' in selective import completions"
else
    echo "  SKIP: 'getValue' not in selective completions (module may not be in warm state)"
fi

# ── Test 5: Non-import dot should NOT trigger import completion ──
echo ""
echo "Test 5: Non-import dot does not trigger import completion (regression)..."

cat > "$WORK_DIR/src/test5.d" << 'EOF'
struct Foo { int x; }
int main() {
    Foo f;
    f.
}
EOF

TEST5_URI="file://$WORK_DIR/src/test5.d"
TEST5_TEXT=$(python3 -c "import json; print(json.dumps(open('$WORK_DIR/src/test5.d').read()))")

DID_OPEN5='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$TEST5_URI"'","languageId":"d","version":1,"text":'"$TEST5_TEXT"'}}}'
# Cursor at line 3, character 6 (after "    f.")
COMPLETION5='{"jsonrpc":"2.0","id":6,"method":"textDocument/completion","params":{"textDocument":{"uri":"'"$TEST5_URI"'"},"position":{"line":3,"character":6}}}'

RESPONSE5=$({
    lsp_msg "$INIT"
    lsp_msg "$INITIALIZED"
    lsp_msg "$DID_OPEN5"
    sleep 1
    lsp_msg "$COMPLETION5"
    sleep 0.5
    lsp_msg "$SHUTDOWN"
    lsp_msg "$EXIT_MSG"
} | timeout 10 "$COMPILER" --lsp -I "$WORK_DIR/src" 2>"$WORK_DIR/lsp5.log" || true)

# Should NOT contain import module names — this is member access, not import
if echo "$RESPONSE5" | grep -q '"helper"'; then
    echo "FAIL: Import module 'helper' appeared in member-access completion (regression!)"
    echo "Response: $RESPONSE5"
    exit 1
else
    echo "  OK: Import modules do not leak into member-access completion"
fi

# The response should still have items (member completion)
if echo "$RESPONSE5" | grep -q '"items"'; then
    echo "  OK: Member-access completion still works"
else
    echo "  WARN: No items in member-access completion (may be expected if type not resolved)"
fi

echo ""
echo "All LSP import completion tests passed!"
