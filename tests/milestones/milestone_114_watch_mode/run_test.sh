#!/bin/bash
# Test: Watch mode CLI integration

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPILER="$SCRIPT_DIR/../../../d2wasm"
TEST_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$TEST_DIR"
    # Kill any lingering watch processes
    pkill -f "d2wasm.*--watch" 2>/dev/null || true
}
trap cleanup EXIT

# Create test file
cat > "$TEST_DIR/test.d" << 'EOF'
int main() { return 42; }
EOF

# Test 1: Watch mode initial compile
echo "Test 1: Watch mode initial compile..."

# Start watch mode in background
"$COMPILER" --watch "$TEST_DIR/test.d" -o "$TEST_DIR/test.wasm" &
PID=$!

# Wait for initial compile
sleep 1

# Check if WASM was created
if [ ! -f "$TEST_DIR/test.wasm" ]; then
    echo "FAIL: WASM file not created"
    kill $PID 2>/dev/null
    exit 1
fi

# Verify the result
RESULT=$(wasm3 --func main "$TEST_DIR/test.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*')
if [ "$RESULT" != "42" ]; then
    echo "FAIL: Expected 42, got $RESULT"
    kill $PID 2>/dev/null
    exit 1
fi
echo "  OK: Initial compile correct"

# Test 2: File change triggers recompile
echo "Test 2: File change triggers recompile..."

# Modify the file
cat > "$TEST_DIR/test.d" << 'EOF'
int main() { return 99; }
EOF

# Wait for recompile
sleep 1

# Verify the result changed
RESULT2=$(wasm3 --func main "$TEST_DIR/test.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*')
if [ "$RESULT2" != "99" ]; then
    echo "FAIL: Expected 99 after change, got $RESULT2"
    kill $PID 2>/dev/null
    exit 1
fi
echo "  OK: Recompile after change correct"

# Clean up
kill $PID 2>/dev/null
wait $PID 2>/dev/null || true

echo "All watch mode tests passed!"
