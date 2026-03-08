#!/bin/bash
# Test: Persistent code cache behavior across compilations

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPILER="$SCRIPT_DIR/../../../d2wasm"
CACHE_DIR=$(mktemp -d)
TEST_FILE="$CACHE_DIR/test.d"

cleanup() {
    rm -rf "$CACHE_DIR"
}
trap cleanup EXIT

# Create test source
cat > "$TEST_FILE" << 'EOF'
int add(int a, int b) {
    return a + b;
}

int main() {
    return add(1, 2);
}
EOF

# Test 1: First compilation - should have all cache misses
echo "Test 1: First compilation..."
OUTPUT1=$("$COMPILER" "$TEST_FILE" -o "$CACHE_DIR/test.wasm" --cache="$CACHE_DIR/cache" --json)
HITS1=$(echo "$OUTPUT1" | grep -o '"cacheHits": [0-9]*' | grep -o '[0-9]*')
MISSES1=$(echo "$OUTPUT1" | grep -o '"cacheMisses": [0-9]*' | grep -o '[0-9]*')

if [ "$HITS1" != "0" ] || [ "$MISSES1" != "8" ]; then
    echo "FAIL: First compile should have 0 hits, 8 misses. Got hits=$HITS1 misses=$MISSES1"
    exit 1
fi
echo "  OK: 0 hits, 8 misses"

# Test 2: Second compilation (same source) - should have all cache hits
echo "Test 2: Second compilation (same source)..."
OUTPUT2=$("$COMPILER" "$TEST_FILE" -o "$CACHE_DIR/test.wasm" --cache="$CACHE_DIR/cache" --json)
HITS2=$(echo "$OUTPUT2" | grep -o '"cacheHits": [0-9]*' | grep -o '[0-9]*')
MISSES2=$(echo "$OUTPUT2" | grep -o '"cacheMisses": [0-9]*' | grep -o '[0-9]*')

if [ "$HITS2" != "8" ] || [ "$MISSES2" != "0" ]; then
    echo "FAIL: Second compile should have 8 hits, 0 misses. Got hits=$HITS2 misses=$MISSES2"
    exit 1
fi
echo "  OK: 8 hits, 0 misses"

# Test 3: Modified source - changed function AND its callers should miss
# add() changed, and main() calls add(), so dep-graph invalidation evicts both
echo "Test 3: Modified source..."
cat > "$TEST_FILE" << 'EOF'
int add(int a, int b) {
    return a + b + 1;
}

int main() {
    return add(1, 2);
}
EOF

OUTPUT3=$("$COMPILER" "$TEST_FILE" -o "$CACHE_DIR/test.wasm" --cache="$CACHE_DIR/cache" --json)
HITS3=$(echo "$OUTPUT3" | grep -o '"cacheHits": [0-9]*' | grep -o '[0-9]*')
MISSES3=$(echo "$OUTPUT3" | grep -o '"cacheMisses": [0-9]*' | grep -o '[0-9]*')

if [ "$HITS3" != "6" ] || [ "$MISSES3" != "2" ]; then
    echo "FAIL: Modified source should have 6 hits, 2 misses. Got hits=$HITS3 misses=$MISSES3"
    exit 1
fi
echo "  OK: 6 hits, 2 misses"

# Test 4: Verify correctness of output
RESULT=$(wasm3 --func _D4test4mainFZi "$CACHE_DIR/test.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$RESULT" != "4" ]; then
    echo "FAIL: Expected result 4, got $RESULT"
    exit 1
fi
echo "  OK: Result = 4"

echo "All cache tests passed!"
