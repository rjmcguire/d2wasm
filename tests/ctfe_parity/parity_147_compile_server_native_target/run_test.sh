#!/bin/bash
# Parity test: Persistent code cache with arm64-macos target
#
# Same test as parity_143 but with --target=arm64-macos -c (compile-only).
# Verifies cache + dep-graph invalidation + JSON output work for native target.
#
# Args: $1 = CTFE backend (wasm|native), $2 = compiler path

set -e

BACKEND="${1:?usage: run_test.sh <backend> <compiler>}"
COMPILER="${2:?usage: run_test.sh <backend> <compiler>}"

# Native target only works on macOS ARM64
if [ "$(uname)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "SKIP: arm64-macos target requires macOS ARM64"
    exit 0
fi

WORK_DIR=$(mktemp -d)

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

cat > "$WORK_DIR/test.d" << 'EOF'
int add(int a, int b) {
    return a + b;
}

int main() {
    return add(1, 2);
}
EOF

# Test 1: First compile — all cache misses
OUT1=$("$COMPILER" "$WORK_DIR/test.d" -o "$WORK_DIR/test.o" --target=arm64-macos -c --backend="$BACKEND" --cache="$WORK_DIR/cache" --json 2>&1)
HITS1=$(echo "$OUT1" | grep -o '"cacheHits": [0-9]*' | grep -o '[0-9]*' || true)
MISSES1=$(echo "$OUT1" | grep -o '"cacheMisses": [0-9]*' | grep -o '[0-9]*' || true)

if [ -z "$HITS1" ] || [ -z "$MISSES1" ]; then
    echo "FAIL: No JSON cache output from native target compile"
    echo "Output: $OUT1"
    exit 1
fi

if [ "$HITS1" != "0" ]; then
    echo "FAIL: First compile should have 0 hits. Got hits=$HITS1 misses=$MISSES1"
    exit 1
fi
echo "  OK: hits=$HITS1, misses=$MISSES1"

# Test 2: Second compile (same source) — all cache hits
OUT2=$("$COMPILER" "$WORK_DIR/test.d" -o "$WORK_DIR/test.o" --target=arm64-macos -c --backend="$BACKEND" --cache="$WORK_DIR/cache" --json 2>&1)
HITS2=$(echo "$OUT2" | grep -o '"cacheHits": [0-9]*' | grep -o '[0-9]*')
MISSES2=$(echo "$OUT2" | grep -o '"cacheMisses": [0-9]*' | grep -o '[0-9]*')

if [ "$MISSES2" != "0" ]; then
    echo "FAIL: Second compile should have 0 misses. Got hits=$HITS2 misses=$MISSES2"
    exit 1
fi
echo "  OK: hits=$HITS2, misses=$MISSES2"

# Test 3: Modified source — partial cache hits
cat > "$WORK_DIR/test.d" << 'EOF'
int add(int a, int b) {
    return a + b + 1;
}

int main() {
    return add(1, 2);
}
EOF

OUT3=$("$COMPILER" "$WORK_DIR/test.d" -o "$WORK_DIR/test.o" --target=arm64-macos -c --backend="$BACKEND" --cache="$WORK_DIR/cache" --json 2>&1)
MISSES3=$(echo "$OUT3" | grep -o '"cacheMisses": [0-9]*' | grep -o '[0-9]*')

if [ "$MISSES3" = "0" ]; then
    echo "FAIL: Modified source should have some misses"
    exit 1
fi
echo "  OK: misses=$MISSES3 after modification"
