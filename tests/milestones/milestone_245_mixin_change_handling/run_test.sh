#!/bin/bash
# Test: Mixin change handling
#
# Tests that when a mixin's CTFE input changes:
#   1. Old expansion symbols are correctly removed
#   2. New expansion symbols are correctly added
#   3. Callers of mixin-produced functions work correctly

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

cat > "$WORK_DIR/test.d" << 'EOF'
mixin("int mixedFunc() { return 5; }");

int normalFunc() {
    return mixedFunc() + 1;
}

int main() {
    return normalFunc();
}
EOF

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
# Test 1: First compile — mixin expands to mixedFunc() returning 5
###############################################################################
echo "Test 1: First compile..."
RESP1=$(send_request '{"id":1,"method":"compile","params":{"file":"'"$WORK_DIR/test.d"'","output":"'"$WORK_DIR/test.wasm"'"}}')

if ! echo "$RESP1" | grep -q '"success":true'; then
    echo "FAIL: First compile failed"
    echo "Response: $RESP1"
    exit 1
fi

R1=$(wasm3 --func _D4test4mainFZi "$WORK_DIR/test.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$R1" != "6" ]; then
    echo "FAIL: Expected 6 (5+1), got $R1"
    exit 1
fi
echo "  OK: result=$R1"

###############################################################################
# Test 2: Same source — warm hits
###############################################################################
echo "Test 2: Same source..."
RESP2=$(send_request '{"id":2,"method":"compile","params":{"file":"'"$WORK_DIR/test.d"'","output":"'"$WORK_DIR/test.wasm"'"}}')

MISSES2=$(echo "$RESP2" | grep -o '"cacheMisses":[0-9]*' | grep -o '[0-9]*')
if [ "$MISSES2" != "0" ]; then
    echo "FAIL: Same source should have 0 misses, got $MISSES2"
    exit 1
fi
echo "  OK: 0 misses"

###############################################################################
# Test 3: Change mixin body — mixedFunc now returns 50
###############################################################################
echo "Test 3: Change mixin body..."
cat > "$WORK_DIR/test.d" << 'EOF'
mixin("int mixedFunc() { return 50; }");

int normalFunc() {
    return mixedFunc() + 1;
}

int main() {
    return normalFunc();
}
EOF

RESP3=$(send_request '{"id":3,"method":"compile","params":{"file":"'"$WORK_DIR/test.d"'","output":"'"$WORK_DIR/test.wasm"'"}}')

if ! echo "$RESP3" | grep -q '"success":true'; then
    echo "FAIL: Third compile failed"
    echo "Response: $RESP3"
    cat "$WORK_DIR/server.log"
    exit 1
fi

R3=$(wasm3 --func _D4test4mainFZi "$WORK_DIR/test.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$R3" != "51" ]; then
    echo "FAIL: Expected 51 (50+1), got $R3"
    exit 1
fi
echo "  OK: result=$R3 (mixin change propagated to caller)"

###############################################################################
# Test 4: Fourth compile — new value cached
###############################################################################
echo "Test 4: Same source again..."
RESP4=$(send_request '{"id":4,"method":"compile","params":{"file":"'"$WORK_DIR/test.d"'","output":"'"$WORK_DIR/test.wasm"'"}}')

MISSES4=$(echo "$RESP4" | grep -o '"cacheMisses":[0-9]*' | grep -o '[0-9]*')
if [ "$MISSES4" != "0" ]; then
    echo "FAIL: Same source should have 0 misses, got $MISSES4"
    exit 1
fi

R4=$(wasm3 --func _D4test4mainFZi "$WORK_DIR/test.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$R4" != "51" ]; then
    echo "FAIL: Expected 51, got $R4"
    exit 1
fi
echo "  OK: 0 misses, result=$R4"

# Shutdown
send_request '{"id":10,"method":"shutdown"}' >/dev/null 2>&1 || true
sleep 0.3

echo "All mixin change handling tests passed!"
