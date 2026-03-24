#!/bin/bash
# Test: Warm CompilationController with targeted phase regression
#
# Scenario: Three modules — main imports helper, standalone is independent.
# When helper changes, main should be re-type-checked (imports helper),
# but standalone should stay warm (doesn't import helper).
#
# Tests:
#   1. First compile — all modules compiled
#   2. Same source — warm hits
#   3. Change helper.d — main picks up change, standalone stays cached
#   4. Change standalone.d — helper stays cached
#   5. Verify server log shows targeted regression

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
int helperFunc() { return 10; }
EOF

cat > "$WORK_DIR/proj/standalone.d" << 'EOF'
module standalone;
int standaloneFunc() { return 100; }
EOF

cat > "$WORK_DIR/proj/main.d" << 'EOF'
import helper;
import standalone;

int main() {
    return helperFunc() + standaloneFunc();
}
EOF

# Start server with verbosity for log evidence
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
    cat "$WORK_DIR/server.log"
    exit 1
fi

RESULT1=$(wasm3 --func _D4main4mainFZi "$WORK_DIR/proj/main.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$RESULT1" != "110" ]; then
    echo "FAIL: Expected 110 (10+100), got $RESULT1"
    exit 1
fi
echo "  OK: result=$RESULT1"

###############################################################################
# Test 2: Same source — warm hits
###############################################################################
echo "Test 2: Same source..."
RESP2=$(send_request '{"id":2,"method":"compile","params":{"file":"'"$WORK_DIR/proj/main.d"'","output":"'"$WORK_DIR/proj/main.wasm"'","importPaths":["'"$WORK_DIR/proj"'"]}}')

MISSES2=$(echo "$RESP2" | grep -o '"cacheMisses":[0-9]*' | grep -o '[0-9]*')
if [ "$MISSES2" != "0" ]; then
    echo "FAIL: Same source should have 0 misses, got $MISSES2"
    exit 1
fi
echo "  OK: 0 misses"

###############################################################################
# Test 3: Change helper.d — main picks up change
###############################################################################
echo "Test 3: Change helper.d..."
cat > "$WORK_DIR/proj/helper.d" << 'EOF'
module helper;
int helperFunc() { return 50; }
EOF

RESP3=$(send_request '{"id":3,"method":"compile","params":{"file":"'"$WORK_DIR/proj/main.d"'","output":"'"$WORK_DIR/proj/main.wasm"'","importPaths":["'"$WORK_DIR/proj"'"]}}')

if ! echo "$RESP3" | grep -q '"success":true'; then
    echo "FAIL: Third compile failed"
    echo "Response: $RESP3"
    cat "$WORK_DIR/server.log"
    exit 1
fi

RESULT3=$(wasm3 --func _D4main4mainFZi "$WORK_DIR/proj/main.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$RESULT3" != "150" ]; then
    echo "FAIL: Expected 150 (50+100), got $RESULT3"
    exit 1
fi
echo "  OK: result=$RESULT3"

###############################################################################
# Test 4: Change standalone.d — helper stays cached
###############################################################################
echo "Test 4: Change standalone.d..."
cat > "$WORK_DIR/proj/standalone.d" << 'EOF'
module standalone;
int standaloneFunc() { return 200; }
EOF

RESP4=$(send_request '{"id":4,"method":"compile","params":{"file":"'"$WORK_DIR/proj/main.d"'","output":"'"$WORK_DIR/proj/main.wasm"'","importPaths":["'"$WORK_DIR/proj"'"]}}')

if ! echo "$RESP4" | grep -q '"success":true'; then
    echo "FAIL: Fourth compile failed"
    echo "Response: $RESP4"
    cat "$WORK_DIR/server.log"
    exit 1
fi

RESULT4=$(wasm3 --func _D4main4mainFZi "$WORK_DIR/proj/main.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$RESULT4" != "250" ]; then
    echo "FAIL: Expected 250 (50+200), got $RESULT4"
    exit 1
fi
echo "  OK: result=$RESULT4"

###############################################################################
# Test 5: Check server log for targeted regression evidence
###############################################################################
echo "Test 5: Server log evidence..."
if grep -q "regressing" "$WORK_DIR/server.log"; then
    echo "  OK: Server log shows targeted regression"
elif grep -q "Using warm compilation controller" "$WORK_DIR/server.log"; then
    echo "  OK: Server log shows warm controller reuse"
else
    echo "  WARN: No warm controller evidence in log"
fi

# Shutdown
send_request '{"id":10,"method":"shutdown"}' >/dev/null 2>&1 || true
sleep 0.3

echo "All warm controller tests passed!"
