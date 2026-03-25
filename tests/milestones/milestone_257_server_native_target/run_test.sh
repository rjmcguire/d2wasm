#!/bin/bash
# Test: Compile server with arm64-macos target
#
# Tests:
#   1. Start server, compile to native .o via target param
#   2. Re-compile — warm cache hits
#   3. Modify source — partial invalidation
#   4. Verify .o files are valid (nm shows symbols)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPILER="$SCRIPT_DIR/../../../d2wasm"
WORK_DIR=$(mktemp -d)
SOCKET="$WORK_DIR/server.sock"

# Native target only works on macOS ARM64
if [ "$(uname)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "SKIP: arm64-macos target requires macOS ARM64"
    exit 0
fi

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

cat > "$WORK_DIR/test.d" << 'EOF'
int add(int a, int b) {
    return a + b;
}

int main() {
    return add(1, 2);
}
EOF

# Start server
"$COMPILER" --server --socket="$SOCKET" --idle-timeout=30 2>"$WORK_DIR/server.log" &
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
# Test 1: First compile with native target
###############################################################################
echo "Test 1: First compile (native target)..."
RESP1=$(send_request '{"id":1,"method":"compile","params":{"file":"'"$WORK_DIR/test.d"'","output":"'"$WORK_DIR/test.o"'","target":"arm64-macos"}}')

if ! echo "$RESP1" | grep -q '"success":true'; then
    echo "FAIL: First compile failed"
    echo "Response: $RESP1"
    cat "$WORK_DIR/server.log"
    exit 1
fi

# Verify .o file exists and has symbols
if [ ! -f "$WORK_DIR/test.o" ]; then
    echo "FAIL: Output .o file not created"
    exit 1
fi

if ! nm "$WORK_DIR/test.o" 2>/dev/null | grep -q "main"; then
    echo "FAIL: .o file missing main symbol"
    exit 1
fi

HITS1=$(echo "$RESP1" | grep -o '"cacheHits":[0-9]*' | grep -o '[0-9]*')
echo "  OK: compiled, hits=$HITS1"

###############################################################################
# Test 2: Same source — warm cache hits
###############################################################################
echo "Test 2: Same source..."
RESP2=$(send_request '{"id":2,"method":"compile","params":{"file":"'"$WORK_DIR/test.d"'","output":"'"$WORK_DIR/test.o"'","target":"arm64-macos"}}')

MISSES2=$(echo "$RESP2" | grep -o '"cacheMisses":[0-9]*' | grep -o '[0-9]*')
if [ "$MISSES2" != "0" ]; then
    echo "FAIL: Second compile should have 0 misses, got $MISSES2"
    exit 1
fi
echo "  OK: 0 misses"

###############################################################################
# Test 3: Modify source — partial invalidation
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

RESP3=$(send_request '{"id":3,"method":"compile","params":{"file":"'"$WORK_DIR/test.d"'","output":"'"$WORK_DIR/test.o"'","target":"arm64-macos"}}')

if ! echo "$RESP3" | grep -q '"success":true'; then
    echo "FAIL: Third compile failed"
    echo "Response: $RESP3"
    exit 1
fi

MISSES3=$(echo "$RESP3" | grep -o '"cacheMisses":[0-9]*' | grep -o '[0-9]*')
if [ "$MISSES3" = "0" ]; then
    echo "FAIL: Modified source should have some misses"
    exit 1
fi
echo "  OK: misses=$MISSES3"

# Shutdown
send_request '{"id":10,"method":"shutdown"}' >/dev/null 2>&1 || true
sleep 0.3

echo "All server native target tests passed!"
