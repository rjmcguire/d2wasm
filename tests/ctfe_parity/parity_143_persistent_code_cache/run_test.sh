#!/bin/bash
# Parity test: Persistent code cache across compilations
# Adapted from milestone_110_persistent_code_cache
#
# Args: $1 = CTFE backend (wasm|native), $2 = compiler path

set -e

BACKEND="${1:?usage: run_test.sh <backend> <compiler>}"
COMPILER="${2:?usage: run_test.sh <backend> <compiler>}"
WORK_DIR=$(mktemp -d)

cleanup() { rm -rf "$WORK_DIR"; }
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

# Test 1: First compilation — all cache misses
OUT1=$("$COMPILER" "$WORK_DIR/test.d" -o "$WORK_DIR/test.wasm" --backend="$BACKEND" --cache="$WORK_DIR/cache" --json)
HITS1=$(echo "$OUT1" | grep -o '"cacheHits": [0-9]*' | grep -o '[0-9]*')
MISSES1=$(echo "$OUT1" | grep -o '"cacheMisses": [0-9]*' | grep -o '[0-9]*')

if [ "$HITS1" != "0" ]; then
    echo "FAIL: First compile should have 0 hits. Got hits=$HITS1 misses=$MISSES1"
    exit 1
fi

# Test 2: Second compilation (same source) — all cache hits
OUT2=$("$COMPILER" "$WORK_DIR/test.d" -o "$WORK_DIR/test.wasm" --backend="$BACKEND" --cache="$WORK_DIR/cache" --json)
HITS2=$(echo "$OUT2" | grep -o '"cacheHits": [0-9]*' | grep -o '[0-9]*')
MISSES2=$(echo "$OUT2" | grep -o '"cacheMisses": [0-9]*' | grep -o '[0-9]*')

if [ "$MISSES2" != "0" ]; then
    echo "FAIL: Second compile should have 0 misses. Got hits=$HITS2 misses=$MISSES2"
    exit 1
fi

# Test 3: Modified source — changed function + callers should miss
cat > "$WORK_DIR/test.d" << 'EOF'
int add(int a, int b) {
    return a + b + 1;
}

int main() {
    return add(1, 2);
}
EOF

OUT3=$("$COMPILER" "$WORK_DIR/test.d" -o "$WORK_DIR/test.wasm" --backend="$BACKEND" --cache="$WORK_DIR/cache" --json)
HITS3=$(echo "$OUT3" | grep -o '"cacheHits": [0-9]*' | grep -o '[0-9]*')
MISSES3=$(echo "$OUT3" | grep -o '"cacheMisses": [0-9]*' | grep -o '[0-9]*')

if [ "$MISSES3" = "0" ]; then
    echo "FAIL: Modified source should have some misses. Got hits=$HITS3 misses=$MISSES3"
    exit 1
fi

# Test 4: Verify correctness of output
RESULT=$(wasm3 --func _D4test4mainFZi "$WORK_DIR/test.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$RESULT" != "4" ]; then
    echo "FAIL: Expected result 4, got $RESULT"
    exit 1
fi
