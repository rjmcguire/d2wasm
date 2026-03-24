#!/bin/bash
# Parity test: Compile server with warm code cache
#
# Tests:
#   1. Start server, compile a file, verify result
#   2. Re-compile same file — warm cache should give all hits
#   3. Modify source, compile again — partial cache hits
#   4. Verify correctness of modified output
#   5. Shutdown server
#
# Args: $1 = CTFE backend (wasm|native), $2 = compiler path

set -e

BACKEND="${1:?usage: run_test.sh <backend> <compiler>}"
COMPILER="${2:?usage: run_test.sh <backend> <compiler>}"
WORK_DIR=$(mktemp -d)
SOCKET="$WORK_DIR/server.sock"

cleanup() {
    # Shutdown server if running
    if [ -S "$SOCKET" ]; then
        echo '{"id":999,"method":"shutdown"}' | nc -U "$SOCKET" >/dev/null 2>&1 || true
        sleep 0.3
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
"$COMPILER" --server --socket="$SOCKET" --backend="$BACKEND" --idle-timeout=30 &
SERVER_PID=$!

# Wait for server to be ready
for i in $(seq 1 50); do
    if [ -S "$SOCKET" ]; then
        break
    fi
    sleep 0.1
done

if [ ! -S "$SOCKET" ]; then
    echo "FAIL: Server did not start"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
fi

# Helper: send request and read response
send_request() {
    echo "$1" | nc -U "$SOCKET" 2>/dev/null
}

# Test 1: First compile — should succeed
REQ1='{"id":1,"method":"compile","params":{"file":"'"$WORK_DIR/test.d"'","output":"'"$WORK_DIR/test.wasm"'"}}'
RESP1=$(send_request "$REQ1")

if ! echo "$RESP1" | grep -q '"success":true'; then
    echo "FAIL: First compile failed"
    echo "Response: $RESP1"
    exit 1
fi

# Verify wasm output is valid
RESULT1=$(wasm3 --func _D4test4mainFZi "$WORK_DIR/test.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$RESULT1" != "3" ]; then
    echo "FAIL: Expected result 3, got $RESULT1"
    exit 1
fi

# Test 2: Same file — warm cache should give hits
REQ2='{"id":2,"method":"compile","params":{"file":"'"$WORK_DIR/test.d"'","output":"'"$WORK_DIR/test.wasm"'"}}'
RESP2=$(send_request "$REQ2")

if ! echo "$RESP2" | grep -q '"success":true'; then
    echo "FAIL: Second compile failed"
    echo "Response: $RESP2"
    exit 1
fi

# Extract cache misses — should be 0
MISSES2=$(echo "$RESP2" | grep -o '"cacheMisses":[0-9]*' | grep -o '[0-9]*')
if [ "$MISSES2" != "0" ]; then
    echo "FAIL: Second compile should have 0 misses, got $MISSES2"
    echo "Response: $RESP2"
    exit 1
fi

# Test 3: Modify source
cat > "$WORK_DIR/test.d" << 'EOF'
int add(int a, int b) {
    return a + b + 1;
}

int main() {
    return add(1, 2);
}
EOF

REQ3='{"id":3,"method":"compile","params":{"file":"'"$WORK_DIR/test.d"'","output":"'"$WORK_DIR/test.wasm"'"}}'
RESP3=$(send_request "$REQ3")

if ! echo "$RESP3" | grep -q '"success":true'; then
    echo "FAIL: Third compile failed"
    echo "Response: $RESP3"
    exit 1
fi

# Test 4: Verify correctness after modification
RESULT3=$(wasm3 --func _D4test4mainFZi "$WORK_DIR/test.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$RESULT3" != "4" ]; then
    echo "FAIL: Expected result 4 after modification, got $RESULT3"
    exit 1
fi

# Modified source should have some misses
MISSES3=$(echo "$RESP3" | grep -o '"cacheMisses":[0-9]*' | grep -o '[0-9]*')
if [ "$MISSES3" = "0" ]; then
    echo "FAIL: Third compile should have some misses after modification"
    exit 1
fi

# Test 5: Status check
REQ_STATUS='{"id":4,"method":"status"}'
RESP_STATUS=$(send_request "$REQ_STATUS")
if ! echo "$RESP_STATUS" | grep -q '"compilations":3'; then
    echo "FAIL: Expected 3 compilations in status"
    echo "Response: $RESP_STATUS"
    exit 1
fi

# Test 6: Shutdown
REQ_SHUTDOWN='{"id":5,"method":"shutdown"}'
send_request "$REQ_SHUTDOWN" >/dev/null 2>&1 || true
sleep 0.5

# Server should have stopped
if kill -0 $SERVER_PID 2>/dev/null; then
    echo "FAIL: Server did not shutdown"
    exit 1
fi
