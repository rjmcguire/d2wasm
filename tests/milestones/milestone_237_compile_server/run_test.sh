#!/bin/bash
# Test: Compile server with warm code cache
#
# Tests:
#   1. Start server, compile a file — all cache misses
#   2. Re-compile same file — warm cache gives all hits
#   3. Modify source — dep-graph invalidation, partial hits
#   4. Verify correctness of modified output
#   5. Status shows 3 compilations
#   6. Shutdown server cleanly

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPILER="$SCRIPT_DIR/../../../d2wasm"
WORK_DIR=$(mktemp -d)
SOCKET="$WORK_DIR/server.sock"

cleanup() {
    # Shutdown server if socket exists
    if [ -S "$SOCKET" ]; then
        echo '{"id":999,"method":"shutdown"}' | nc -U "$SOCKET" >/dev/null 2>&1 || true
        sleep 0.5
    fi
    # Kill server if still running
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Create test source
cat > "$WORK_DIR/test.d" << 'EOF'
int add(int a, int b) {
    return a + b;
}

int main() {
    return add(1, 2);
}
EOF

# Start server in background
"$COMPILER" --server --socket="$SOCKET" --idle-timeout=60 2>"$WORK_DIR/server.log" &
SERVER_PID=$!

# Wait for server to be ready (up to 5 seconds)
for i in $(seq 1 50); do
    if [ -S "$SOCKET" ]; then break; fi
    sleep 0.1
done

if [ ! -S "$SOCKET" ]; then
    echo "FAIL: Server did not start"
    cat "$WORK_DIR/server.log"
    exit 1
fi

###############################################################################
# Test 1: First compile — all cache misses
###############################################################################
echo "Test 1: First compile..."
RESP1=$(echo '{"id":1,"method":"compile","params":{"file":"'"$WORK_DIR/test.d"'","output":"'"$WORK_DIR/test.wasm"'"}}' | nc -U "$SOCKET")

if ! echo "$RESP1" | grep -q '"success":true'; then
    echo "FAIL: First compile failed"
    echo "Response: $RESP1"
    exit 1
fi

HITS1=$(echo "$RESP1" | grep -o '"cacheHits":[0-9]*' | grep -o '[0-9]*')
MISSES1=$(echo "$RESP1" | grep -o '"cacheMisses":[0-9]*' | grep -o '[0-9]*')

if [ "$HITS1" != "0" ]; then
    echo "FAIL: First compile should have 0 hits. Got hits=$HITS1 misses=$MISSES1"
    exit 1
fi
echo "  OK: hits=$HITS1, misses=$MISSES1"

# Verify output
RESULT1=$(wasm3 --func _D4test4mainFZi "$WORK_DIR/test.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$RESULT1" != "3" ]; then
    echo "FAIL: Expected result 3, got $RESULT1"
    exit 1
fi
echo "  OK: result=$RESULT1"

###############################################################################
# Test 2: Same source — warm cache gives all hits
###############################################################################
echo "Test 2: Second compile (same source)..."
RESP2=$(echo '{"id":2,"method":"compile","params":{"file":"'"$WORK_DIR/test.d"'","output":"'"$WORK_DIR/test.wasm"'"}}' | nc -U "$SOCKET")

HITS2=$(echo "$RESP2" | grep -o '"cacheHits":[0-9]*' | grep -o '[0-9]*')
MISSES2=$(echo "$RESP2" | grep -o '"cacheMisses":[0-9]*' | grep -o '[0-9]*')

if [ "$MISSES2" != "0" ]; then
    echo "FAIL: Second compile should have 0 misses. Got hits=$HITS2 misses=$MISSES2"
    exit 1
fi
echo "  OK: hits=$HITS2, misses=$MISSES2"

###############################################################################
# Test 3: Modified source — dep-graph invalidation
###############################################################################
echo "Test 3: Modified source..."
cat > "$WORK_DIR/test.d" << 'EOF'
int add(int a, int b) {
    return a + b + 1;
}

int main() {
    return add(1, 2);
}
EOF

RESP3=$(echo '{"id":3,"method":"compile","params":{"file":"'"$WORK_DIR/test.d"'","output":"'"$WORK_DIR/test.wasm"'"}}' | nc -U "$SOCKET")

HITS3=$(echo "$RESP3" | grep -o '"cacheHits":[0-9]*' | grep -o '[0-9]*')
MISSES3=$(echo "$RESP3" | grep -o '"cacheMisses":[0-9]*' | grep -o '[0-9]*')

if [ "$MISSES3" = "0" ]; then
    echo "FAIL: Modified source should have some misses. Got hits=$HITS3 misses=$MISSES3"
    exit 1
fi
echo "  OK: hits=$HITS3, misses=$MISSES3"

###############################################################################
# Test 4: Verify correctness after modification
###############################################################################
echo "Test 4: Verify correctness..."
RESULT3=$(wasm3 --func _D4test4mainFZi "$WORK_DIR/test.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$RESULT3" != "4" ]; then
    echo "FAIL: Expected result 4, got $RESULT3"
    exit 1
fi
echo "  OK: result=$RESULT3"

###############################################################################
# Test 5: Status shows 3 compilations
###############################################################################
echo "Test 5: Status check..."
RESP_STATUS=$(echo '{"id":4,"method":"status"}' | nc -U "$SOCKET")

if ! echo "$RESP_STATUS" | grep -q '"compilations":3'; then
    echo "FAIL: Expected 3 compilations in status"
    echo "Response: $RESP_STATUS"
    exit 1
fi
echo "  OK: status shows 3 compilations"

###############################################################################
# Test 6: Shutdown
###############################################################################
echo "Test 6: Shutdown..."
echo '{"id":5,"method":"shutdown"}' | nc -U "$SOCKET" >/dev/null 2>&1 || true
sleep 1

if kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "FAIL: Server did not shutdown"
    exit 1
fi
echo "  OK: server stopped"

echo "All compile server tests passed!"
