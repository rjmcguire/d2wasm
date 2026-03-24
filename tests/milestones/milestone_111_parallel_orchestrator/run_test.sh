#!/bin/bash
# Test: Parallel compilation orchestrator

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPILER="$SCRIPT_DIR/../../../d2wasm"
TEST_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Create test files
cat > "$TEST_DIR/file1.d" << 'EOF'
int add(int a, int b) { return a + b; }
int run1() { return add(1, 2); }
EOF

cat > "$TEST_DIR/file2.d" << 'EOF'
int mul(int a, int b) { return a * b; }
int run2() { return mul(2, 3); }
EOF

cat > "$TEST_DIR/file3.d" << 'EOF'
int sub(int a, int b) { return a - b; }
int run3() { return sub(10, 4); }
EOF

# Test 1: Parallel compilation of 3 files
echo "Test 1: Parallel compilation of 3 files..."
OUTPUT=$("$COMPILER" "$TEST_DIR/file1.d" "$TEST_DIR/file2.d" "$TEST_DIR/file3.d" \
    --outdir="$TEST_DIR/out" --cache="$TEST_DIR/cache" --json)

SUCCESS=$(echo "$OUTPUT" | grep -o '"success": [0-9]*' | grep -o '[0-9]*')
FAILED=$(echo "$OUTPUT" | grep -o '"failed": [0-9]*' | grep -o '[0-9]*')

if [ "$SUCCESS" != "3" ] || [ "$FAILED" != "0" ]; then
    echo "FAIL: Expected 3 successes, 0 failures. Got success=$SUCCESS failed=$FAILED"
    exit 1
fi
echo "  OK: 3 files compiled successfully"

# Test 2: Verify WASM files were created
echo "Test 2: Verify output files..."
for f in file1.wasm file2.wasm file3.wasm; do
    if [ ! -f "$TEST_DIR/out/$f" ]; then
        echo "FAIL: Missing output file $f"
        exit 1
    fi
done
echo "  OK: All output files created"

# Test 3: Verify WASM correctness
echo "Test 3: Verify WASM correctness..."
R1=$(wasm3 --func _D5file14run1FZi "$TEST_DIR/out/file1.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
R2=$(wasm3 --func _D5file24run2FZi "$TEST_DIR/out/file2.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
R3=$(wasm3 --func _D5file34run3FZi "$TEST_DIR/out/file3.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)

if [ "$R1" != "3" ]; then echo "FAIL: file1 result=$R1, expected 3"; exit 1; fi
if [ "$R2" != "6" ]; then echo "FAIL: file2 result=$R2, expected 6"; exit 1; fi
if [ "$R3" != "6" ]; then echo "FAIL: file3 result=$R3, expected 6"; exit 1; fi
echo "  OK: All results correct"

# Test 4: Second run should have cache hits
echo "Test 4: Second run (cache hits)..."
OUTPUT2=$("$COMPILER" "$TEST_DIR/file1.d" "$TEST_DIR/file2.d" "$TEST_DIR/file3.d" \
    --outdir="$TEST_DIR/out" --cache="$TEST_DIR/cache" --json)

HITS=$(echo "$OUTPUT2" | grep -o '"cacheHits": [0-9]*' | head -1 | grep -o '[0-9]*')
MISSES=$(echo "$OUTPUT2" | grep -o '"cacheMisses": [0-9]*' | head -1 | grep -o '[0-9]*')

if [ "$HITS" != "33" ] || [ "$MISSES" != "0" ]; then
    echo "FAIL: Expected 33 hits, 0 misses. Got hits=$HITS misses=$MISSES"
    exit 1
fi
echo "  OK: 33 cache hits, 0 misses"

echo "All orchestrator tests passed!"
