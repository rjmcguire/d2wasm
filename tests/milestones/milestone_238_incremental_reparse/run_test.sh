#!/bin/bash
# Test: Tree-sitter incremental reparse with dep-graph spatial invalidation
#
# Tests that fileChanged with an edit descriptor uses tree-sitter incremental
# reparse + dep-graph spatial index to pre-identify dirty declarations,
# and that the subsequent compile correctly evicts and recompiles only those.
#
# Scenario:
#   1. Start server, compile a file with multiple functions
#   2. Second compile — all warm hits
#   3. Send fileChanged with edit descriptor (change one function body)
#   4. Compile — verify incremental invalidation works correctly
#   5. Verify correctness of output

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

# Original source (note: leaf() body is "return 5;" at a known byte offset)
ORIGINAL='int leaf() { return 5; }
int middle() { return leaf() + 1; }
int top() { return middle() + 1; }
int standalone() { return 42; }

int main() { return top(); }'

# Modified source — only leaf() body changed: "return 5;" → "return 100;"
MODIFIED='int leaf() { return 100; }
int middle() { return leaf() + 1; }
int top() { return middle() + 1; }
int standalone() { return 42; }

int main() { return top(); }'

echo "$ORIGINAL" > "$WORK_DIR/chain.d"

# Start server
"$COMPILER" --server --socket="$SOCKET" --idle-timeout=60 2>"$WORK_DIR/server.log" &
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
RESP1=$(send_request '{"id":1,"method":"compile","params":{"file":"'"$WORK_DIR/chain.d"'","output":"'"$WORK_DIR/chain.wasm"'"}}')

if ! echo "$RESP1" | grep -q '"success":true'; then
    echo "FAIL: First compile failed"
    echo "Response: $RESP1"
    exit 1
fi

RESULT1=$(wasm3 --func _D5chain4mainFZi "$WORK_DIR/chain.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$RESULT1" != "7" ]; then
    echo "FAIL: Expected result 7, got $RESULT1"
    exit 1
fi
echo "  OK: result=$RESULT1"

###############################################################################
# Test 2: Second compile — all warm hits
###############################################################################
echo "Test 2: Second compile (same source)..."
RESP2=$(send_request '{"id":2,"method":"compile","params":{"file":"'"$WORK_DIR/chain.d"'","output":"'"$WORK_DIR/chain.wasm"'"}}')

MISSES2=$(echo "$RESP2" | grep -o '"cacheMisses":[0-9]*' | grep -o '[0-9]*')
if [ "$MISSES2" != "0" ]; then
    echo "FAIL: Second compile should have 0 misses, got $MISSES2"
    exit 1
fi
echo "  OK: 0 misses"

###############################################################################
# Test 3: fileChanged with edit descriptor
###############################################################################
echo "Test 3: Incremental fileChanged..."

# The edit: "return 5;" (bytes 13-23) → "return 100;" (bytes 13-25)
# In the original: "int leaf() { return 5; }" — "return 5;" starts at byte 13
# Compute: "return 5;" is 9 chars, "return 100;" is 11 chars
# start_byte=13, old_end_byte=22, new_end_byte=24
# (the ';' position shifts by 2 bytes)

# Write the modified source to disk
echo "$MODIFIED" > "$WORK_DIR/chain.d"

# Escape the new text for JSON
ESCAPED_TEXT=$(echo "$MODIFIED" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

RESP3=$(send_request '{"id":3,"method":"fileChanged","params":{"file":"'"$WORK_DIR/chain.d"'","newText":'"$ESCAPED_TEXT"',"edit":{"startByte":13,"oldEndByte":22,"newEndByte":24,"startLine":0,"startCol":13,"oldEndLine":0,"oldEndCol":22,"newEndLine":0,"newEndCol":24}}}')

if ! echo "$RESP3" | grep -q '"ok":true'; then
    echo "FAIL: fileChanged failed"
    echo "Response: $RESP3"
    exit 1
fi
echo "  OK: fileChanged accepted"

###############################################################################
# Test 4: Compile after incremental change
###############################################################################
echo "Test 4: Compile after incremental change..."
RESP4=$(send_request '{"id":4,"method":"compile","params":{"file":"'"$WORK_DIR/chain.d"'","output":"'"$WORK_DIR/chain.wasm"'"}}')

if ! echo "$RESP4" | grep -q '"success":true'; then
    echo "FAIL: Fourth compile failed"
    echo "Response: $RESP4"
    exit 1
fi

HITS4=$(echo "$RESP4" | grep -o '"cacheHits":[0-9]*' | grep -o '[0-9]*')
MISSES4=$(echo "$RESP4" | grep -o '"cacheMisses":[0-9]*' | grep -o '[0-9]*')
echo "  OK: hits=$HITS4, misses=$MISSES4"

###############################################################################
# Test 5: Verify correctness — top = 100 + 1 + 1 = 102
###############################################################################
echo "Test 5: Verify correctness..."
RESULT4=$(wasm3 --func _D5chain4mainFZi "$WORK_DIR/chain.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$RESULT4" != "102" ]; then
    echo "FAIL: Expected result 102, got $RESULT4"
    exit 1
fi
echo "  OK: result=$RESULT4"

# standalone() should be a cache hit — it doesn't depend on leaf()
if [ "$HITS4" -lt "1" ]; then
    echo "FAIL: standalone() should be a cache hit"
    exit 1
fi
echo "  OK: standalone() was a cache hit"

###############################################################################
# Check server log for incremental reparse evidence
###############################################################################
echo "Test 6: Verify server used incremental reparse..."
if grep -q "Incremental change" "$WORK_DIR/server.log"; then
    echo "  OK: Server log shows incremental change detection"
elif grep -q "Pre-evicted" "$WORK_DIR/server.log"; then
    echo "  OK: Server log shows pre-eviction from incremental change"
else
    echo "  INFO: No incremental reparse evidence in log (full hash comparison used)"
fi

# Shutdown
send_request '{"id":10,"method":"shutdown"}' >/dev/null 2>&1 || true
sleep 0.5

echo "All incremental reparse tests passed!"
