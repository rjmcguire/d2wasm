#!/bin/bash
# Test: Selective re-type-check via AST splicing
#
# Uses fileChanged with edit descriptor so tree-sitter computes changed
# byte ranges. The compiler then splices old (type-checked) and new
# (re-parsed) AST nodes, skipping type-checking for unchanged declarations.
#
# Scenario: Module with 5 functions. Change 1 function body.
# Only that function + callers should be re-type-checked.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPILER="$SCRIPT_DIR/../../../d2wasm"
WORK_DIR=$(mktemp -d)
SOCKET="$WORK_DIR/server.sock"

cleanup() {
    if [ -S "$SOCKET" ]; then
        echo '{"id":999,"method":"shutdown"}' | nc -U "$SOCKET" >/dev/null 2>&1 || true
        sleep 0.3
    fi
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Original source
ORIGINAL='int alpha() { return 1; }
int beta() { return 2; }
int gamma() { return alpha() + beta(); }
int delta() { return 100; }

int main() { return gamma() + delta(); }'

# Modified: only alpha's body changes (return 1 → return 10)
MODIFIED='int alpha() { return 10; }
int beta() { return 2; }
int gamma() { return alpha() + beta(); }
int delta() { return 100; }

int main() { return gamma() + delta(); }'

echo "$ORIGINAL" > "$WORK_DIR/test.d"

# Start server with verbosity
"$COMPILER" --server --socket="$SOCKET" --idle-timeout=60 -v -v 2>"$WORK_DIR/server.log" &
SERVER_PID=$!

for i in $(seq 1 50); do
    if [ -S "$SOCKET" ]; then break; fi
    sleep 0.1
done
if [ ! -S "$SOCKET" ]; then
    echo "FAIL: Server did not start"
    cat "$WORK_DIR/server.log"
    exit 1
fi

send_request() {
    echo "$1" | nc -U "$SOCKET" 2>/dev/null
}

###############################################################################
# Test 1: First compile
###############################################################################
echo "Test 1: First compile..."
RESP1=$(send_request '{"id":1,"method":"compile","params":{"file":"'"$WORK_DIR/test.d"'","output":"'"$WORK_DIR/test.wasm"'"}}')

if ! echo "$RESP1" | grep -q '"success":true'; then
    echo "FAIL: First compile failed"
    echo "Response: $RESP1"
    exit 1
fi

RESULT1=$(wasm3 --func _D4test4mainFZi "$WORK_DIR/test.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$RESULT1" != "103" ]; then
    echo "FAIL: Expected 103 (1+2+100), got $RESULT1"
    exit 1
fi
echo "  OK: result=$RESULT1"

###############################################################################
# Test 2: fileChanged with edit descriptor
###############################################################################
echo "Test 2: Incremental fileChanged..."

# The edit: "return 1;" → "return 10;" in alpha()
# "int alpha() { return 1; }" is 26 bytes at offset 0
# "return 1" starts at byte 14, "return 10" is 1 byte longer
# start_byte=14, old_end_byte=22, new_end_byte=23

echo "$MODIFIED" > "$WORK_DIR/test.d"

ESCAPED_TEXT=$(echo "$MODIFIED" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

RESP2=$(send_request '{"id":2,"method":"fileChanged","params":{"file":"'"$WORK_DIR/test.d"'","newText":'"$ESCAPED_TEXT"',"edit":{"startByte":14,"oldEndByte":22,"newEndByte":23,"startLine":0,"startCol":14,"oldEndLine":0,"oldEndCol":22,"newEndLine":0,"newEndCol":23}}}')

if ! echo "$RESP2" | grep -q '"ok":true'; then
    echo "FAIL: fileChanged failed"
    echo "Response: $RESP2"
    exit 1
fi
echo "  OK: fileChanged accepted"

###############################################################################
# Test 3: Compile after incremental change
###############################################################################
echo "Test 3: Compile after incremental change..."
RESP3=$(send_request '{"id":3,"method":"compile","params":{"file":"'"$WORK_DIR/test.d"'","output":"'"$WORK_DIR/test.wasm"'"}}')

if ! echo "$RESP3" | grep -q '"success":true'; then
    echo "FAIL: Compile after change failed"
    echo "Response: $RESP3"
    cat "$WORK_DIR/server.log"
    exit 1
fi

RESULT3=$(wasm3 --func _D4test4mainFZi "$WORK_DIR/test.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$RESULT3" != "112" ]; then
    echo "FAIL: Expected 112 (10+2+100), got $RESULT3"
    exit 1
fi
echo "  OK: result=$RESULT3"

###############################################################################
# Test 4: Verify AST splice happened
###############################################################################
echo "Test 4: Server log evidence..."
if grep -q "AST splice" "$WORK_DIR/server.log"; then
    SPLICE_LINE=$(grep "AST splice" "$WORK_DIR/server.log" | tail -1)
    echo "  OK: $SPLICE_LINE"
else
    echo "FAIL: No AST splice evidence in log"
    exit 1
fi

# delta() should be a cache hit (unchanged, not affected by alpha)
HITS3=$(echo "$RESP3" | grep -o '"cacheHits":[0-9]*' | grep -o '[0-9]*')
if [ "$HITS3" -gt "0" ]; then
    echo "  OK: $HITS3 cache hits (unchanged functions reused)"
fi

# Shutdown
send_request '{"id":10,"method":"shutdown"}' >/dev/null 2>&1 || true
sleep 0.3

echo "All selective re-type-check tests passed!"
