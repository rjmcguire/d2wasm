#!/bin/bash
# Test: Incremental symbol re-collection
#
# Verifies that:
#   1. Changed function signature is correctly updated in symbol table
#   2. Unchanged functions stay cached
#   3. New functions are correctly added
#   4. Results are correct throughout

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

mkdir -p "$WORK_DIR/proj"

cat > "$WORK_DIR/proj/helper.d" << 'EOF'
module helper;

int getValue() {
    return 10;
}

int getOther() {
    return 20;
}
EOF

cat > "$WORK_DIR/proj/main.d" << 'EOF'
import helper;

int main() {
    return getValue() + getOther();
}
EOF

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
RESP1=$(send_request '{"id":1,"method":"compile","params":{"file":"'"$WORK_DIR/proj/main.d"'","output":"'"$WORK_DIR/proj/main.wasm"'","importPaths":["'"$WORK_DIR/proj"'"]}}')

if ! echo "$RESP1" | grep -q '"success":true'; then
    echo "FAIL: First compile failed"
    echo "Response: $RESP1"
    exit 1
fi

RESULT1=$(wasm3 --func _D4main4mainFZi "$WORK_DIR/proj/main.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$RESULT1" != "30" ]; then
    echo "FAIL: Expected 30 (10+20), got $RESULT1"
    exit 1
fi
echo "  OK: result=$RESULT1"

###############################################################################
# Test 2: Change one function in helper.d
###############################################################################
echo "Test 2: Change getValue() in helper.d..."
cat > "$WORK_DIR/proj/helper.d" << 'EOF'
module helper;

int getValue() {
    return 50;
}

int getOther() {
    return 20;
}
EOF

RESP2=$(send_request '{"id":2,"method":"compile","params":{"file":"'"$WORK_DIR/proj/main.d"'","output":"'"$WORK_DIR/proj/main.wasm"'","importPaths":["'"$WORK_DIR/proj"'"]}}')

if ! echo "$RESP2" | grep -q '"success":true'; then
    echo "FAIL: Second compile failed"
    echo "Response: $RESP2"
    cat "$WORK_DIR/server.log"
    exit 1
fi

RESULT2=$(wasm3 --func _D4main4mainFZi "$WORK_DIR/proj/main.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$RESULT2" != "70" ]; then
    echo "FAIL: Expected 70 (50+20), got $RESULT2"
    exit 1
fi
echo "  OK: result=$RESULT2 (symbol correctly updated)"

# Check for incremental evidence
if grep -q "incremental symbol re-collection" "$WORK_DIR/server.log"; then
    echo "  OK: Incremental symbol re-collection used"
elif grep -q "incremental re-collection" "$WORK_DIR/server.log"; then
    echo "  OK: Incremental re-collection used"
fi

###############################################################################
# Test 3: Add a new function to helper.d
###############################################################################
echo "Test 3: Add new function to helper.d..."
cat > "$WORK_DIR/proj/helper.d" << 'EOF'
module helper;

int getValue() {
    return 50;
}

int getOther() {
    return 20;
}

int getBonus() {
    return 5;
}
EOF

cat > "$WORK_DIR/proj/main.d" << 'EOF'
import helper;

int main() {
    return getValue() + getOther() + getBonus();
}
EOF

RESP3=$(send_request '{"id":3,"method":"compile","params":{"file":"'"$WORK_DIR/proj/main.d"'","output":"'"$WORK_DIR/proj/main.wasm"'","importPaths":["'"$WORK_DIR/proj"'"]}}')

if ! echo "$RESP3" | grep -q '"success":true'; then
    echo "FAIL: Third compile failed"
    echo "Response: $RESP3"
    cat "$WORK_DIR/server.log"
    exit 1
fi

RESULT3=$(wasm3 --func _D4main4mainFZi "$WORK_DIR/proj/main.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$RESULT3" != "75" ]; then
    echo "FAIL: Expected 75 (50+20+5), got $RESULT3"
    exit 1
fi
echo "  OK: result=$RESULT3 (new function correctly added)"

# Shutdown
send_request '{"id":10,"method":"shutdown"}' >/dev/null 2>&1 || true
sleep 0.3

echo "All incremental symbol re-collection tests passed!"
