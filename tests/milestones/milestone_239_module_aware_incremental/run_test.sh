#!/bin/bash
# Test: Module-aware incremental compilation
#
# Tests that the compile server's warm module registry avoids
# re-parsing unchanged imported modules across compilations.
#
# Scenario:
#   1. Create main.d that imports helper.d
#   2. First compile — both modules parsed
#   3. Second compile (same source) — warm hits
#   4. Change main.d only — helper.d should not be re-parsed
#   5. Change helper.d — verify main.d picks up the change
#   6. Verify correctness throughout

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

# Create a two-module project
mkdir -p "$WORK_DIR/proj"

cat > "$WORK_DIR/proj/helper.d" << 'EOF'
module helper;

int helperFunc() {
    return 10;
}
EOF

cat > "$WORK_DIR/proj/main.d" << 'EOF'
import helper;

int compute() {
    return helperFunc() + 1;
}

int main() {
    return compute();
}
EOF

# Start server
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
# Test 1: First compile — both modules parsed
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
if [ "$RESULT1" != "11" ]; then
    echo "FAIL: Expected result 11 (10+1), got $RESULT1"
    exit 1
fi
echo "  OK: result=$RESULT1"

###############################################################################
# Test 2: Second compile — warm hits
###############################################################################
echo "Test 2: Second compile (same source)..."
RESP2=$(send_request '{"id":2,"method":"compile","params":{"file":"'"$WORK_DIR/proj/main.d"'","output":"'"$WORK_DIR/proj/main.wasm"'","importPaths":["'"$WORK_DIR/proj"'"]}}')

MISSES2=$(echo "$RESP2" | grep -o '"cacheMisses":[0-9]*' | grep -o '[0-9]*')
if [ "$MISSES2" != "0" ]; then
    echo "FAIL: Second compile should have 0 misses, got $MISSES2"
    exit 1
fi
echo "  OK: 0 misses (warm module registry reused)"

###############################################################################
# Test 3: Change main.d only — helper.d should not be re-parsed
###############################################################################
echo "Test 3: Change main.d only..."
cat > "$WORK_DIR/proj/main.d" << 'EOF'
import helper;

int compute() {
    return helperFunc() + 2;
}

int main() {
    return compute();
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
if [ "$RESULT3" != "12" ]; then
    echo "FAIL: Expected result 12 (10+2), got $RESULT3"
    exit 1
fi
echo "  OK: result=$RESULT3"

# Verify server log shows warm registry was used
if grep -q "Using warm module registry" "$WORK_DIR/server.log"; then
    echo "  OK: Warm module registry reused"
else
    echo "FAIL: Warm module registry not reused"
    exit 1
fi

###############################################################################
# Test 4: Change helper.d — main should pick up the change
###############################################################################
echo "Test 4: Change helper.d..."
cat > "$WORK_DIR/proj/helper.d" << 'EOF'
module helper;

int helperFunc() {
    return 50;
}
EOF

RESP4=$(send_request '{"id":4,"method":"compile","params":{"file":"'"$WORK_DIR/proj/main.d"'","output":"'"$WORK_DIR/proj/main.wasm"'","importPaths":["'"$WORK_DIR/proj"'"]}}')

if ! echo "$RESP4" | grep -q '"success":true'; then
    echo "FAIL: Fourth compile failed"
    echo "Response: $RESP4"
    cat "$WORK_DIR/server.log"
    exit 1
fi

RESULT4=$(wasm3 --func _D4main4mainFZi "$WORK_DIR/proj/main.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$RESULT4" != "52" ]; then
    echo "FAIL: Expected result 52 (50+2), got $RESULT4"
    exit 1
fi
echo "  OK: result=$RESULT4 (picked up helper.d change)"

# Verify server detected re-parse
if grep -q "Re-parsing changed import" "$WORK_DIR/server.log"; then
    echo "  OK: Server re-parsed changed import"
else
    echo "FAIL: Server did not re-parse changed import"
    exit 1
fi

# Shutdown
send_request '{"id":10,"method":"shutdown"}' >/dev/null 2>&1 || true
sleep 0.5

echo "All module-aware incremental tests passed!"
