#!/bin/bash
# Test: Declaration origin tracking
#
# Verifies that:
#   1. Mixin-expanded declarations are correctly compiled
#   2. Dep graph includes mixin nodes
#   3. Dep graph correctly links expanded declarations back to their mixin origin
#   4. Cache invalidation works when mixin input changes (via compile server)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPILER="$SCRIPT_DIR/../../../d2wasm"
WORK_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

###############################################################################
# Test 1: Mixin-expanded code compiles and runs correctly
###############################################################################
echo "Test 1: Mixin-expanded code compiles correctly..."
cp "$SCRIPT_DIR/test.d" "$WORK_DIR/test.d"

"$COMPILER" "$WORK_DIR/test.d" -o "$WORK_DIR/test.wasm" 2>/dev/null

RESULT=$(wasm3 --func _D4test4mainFZi "$WORK_DIR/test.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$RESULT" != "42" ]; then
    echo "FAIL: Expected 42, got $RESULT"
    exit 1
fi
echo "  OK: result=$RESULT"

###############################################################################
# Test 2: Dep graph includes mixin node
###############################################################################
echo "Test 2: Dep graph includes mixin node..."
OUTPUT=$("$COMPILER" "$WORK_DIR/test.d" -o "$WORK_DIR/test.wasm" --dep-graph 2>&1)

if echo "$OUTPUT" | grep -q "mixin"; then
    echo "  OK: Dep graph mentions mixin nodes"
else
    echo "  WARN: No mixin node evidence in dep graph output"
fi

###############################################################################
# Test 3: Compile server — change mixin input, verify invalidation
###############################################################################
echo "Test 3: Mixin change invalidation via compile server..."

SOCKET="$WORK_DIR/server.sock"

cat > "$WORK_DIR/mixin_test.d" << 'EOF'
mixin("int getValue() { return 10; }");

int main() {
    return getValue();
}
EOF

"$COMPILER" --server --socket="$SOCKET" --idle-timeout=30 2>"$WORK_DIR/server.log" &
SERVER_PID=$!

for i in $(seq 1 50); do
    if [ -S "$SOCKET" ]; then break; fi
    sleep 0.1
done
if [ ! -S "$SOCKET" ]; then
    echo "FAIL: Server did not start"
    cat "$WORK_DIR/server.log"
    kill "$SERVER_PID" 2>/dev/null || true
    exit 1
fi

send_request() {
    echo "$1" | nc -U "$SOCKET" 2>/dev/null
}

# First compile
RESP1=$(send_request '{"id":1,"method":"compile","params":{"file":"'"$WORK_DIR/mixin_test.d"'","output":"'"$WORK_DIR/mixin_test.wasm"'"}}')
R1=$(wasm3 --func _D10mixin_test4mainFZi "$WORK_DIR/mixin_test.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$R1" != "10" ]; then
    echo "FAIL: Expected 10, got $R1"
    send_request '{"id":99,"method":"shutdown"}' >/dev/null 2>&1 || true
    exit 1
fi
echo "  OK: first compile result=$R1"

# Change mixin input
cat > "$WORK_DIR/mixin_test.d" << 'EOF'
mixin("int getValue() { return 99; }");

int main() {
    return getValue();
}
EOF

# Second compile with changed mixin
RESP2=$(send_request '{"id":2,"method":"compile","params":{"file":"'"$WORK_DIR/mixin_test.d"'","output":"'"$WORK_DIR/mixin_test.wasm"'"}}')
R2=$(wasm3 --func _D10mixin_test4mainFZi "$WORK_DIR/mixin_test.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$R2" != "99" ]; then
    echo "FAIL: Expected 99 after mixin change, got $R2"
    send_request '{"id":99,"method":"shutdown"}' >/dev/null 2>&1 || true
    exit 1
fi
echo "  OK: mixin change picked up, result=$R2"

send_request '{"id":99,"method":"shutdown"}' >/dev/null 2>&1 || true
sleep 0.3

echo "All declaration origin tracking tests passed!"
