#!/bin/bash
# Parity test: Dependency graph cache invalidation
# Adapted from milestone_204_dep_graph_cache_invalidation
#
# Scenarios:
#   1. CTFE manifest chain: ctfeHelper() -> enum CONST -> consumer()
#   2. Call chain: leaf() -> middle() -> top()
#
# Args: $1 = CTFE backend (wasm|native), $2 = compiler path

set -e

BACKEND="${1:?usage: run_test.sh <backend> <compiler>}"
COMPILER="${2:?usage: run_test.sh <backend> <compiler>}"
WORK_DIR=$(mktemp -d)

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

###############################################################################
# Test 1: CTFE manifest chain invalidation
###############################################################################

cat > "$WORK_DIR/ctfe.d" << 'EOF'
int ctfeHelper() { return 10; }
enum CONST = ctfeHelper();

int consumer() { return CONST + 1; }
int unrelated() { return 99; }

int main() { return consumer(); }
EOF

# First compile: all misses
"$COMPILER" "$WORK_DIR/ctfe.d" -o "$WORK_DIR/ctfe.wasm" --backend="$BACKEND" --cache="$WORK_DIR/cache1" --json > /dev/null

# Verify: consumer() = 10 + 1 = 11
R1=$(wasm3 --func _D4ctfe4mainFZi "$WORK_DIR/ctfe.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$R1" != "11" ]; then
    echo "FAIL: Expected result 11, got $R1"
    exit 1
fi

# Second compile: same source, all hits
OUT2=$("$COMPILER" "$WORK_DIR/ctfe.d" -o "$WORK_DIR/ctfe.wasm" --backend="$BACKEND" --cache="$WORK_DIR/cache1" --json)
MISSES2=$(echo "$OUT2" | grep -o '"cacheMisses": [0-9]*' | grep -o '[0-9]*')
if [ "$MISSES2" != "0" ]; then
    echo "FAIL: Unchanged source should have 0 misses, got $MISSES2"
    exit 1
fi

# Modify ctfeHelper: CONST changes, consumer must be re-emitted
cat > "$WORK_DIR/ctfe.d" << 'EOF'
int ctfeHelper() { return 20; }
enum CONST = ctfeHelper();

int consumer() { return CONST + 1; }
int unrelated() { return 99; }

int main() { return consumer(); }
EOF

OUT3=$("$COMPILER" "$WORK_DIR/ctfe.d" -o "$WORK_DIR/ctfe.wasm" --backend="$BACKEND" --cache="$WORK_DIR/cache1" --json)
HITS3=$(echo "$OUT3" | grep -o '"cacheHits": [0-9]*' | grep -o '[0-9]*')

# Verify: consumer() = 20 + 1 = 21
R3=$(wasm3 --func _D4ctfe4mainFZi "$WORK_DIR/ctfe.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$R3" != "21" ]; then
    echo "FAIL: Expected result 21 after ctfeHelper change, got $R3 (stale cache)"
    exit 1
fi

# unrelated() should still be a cache hit
if [ "$HITS3" -lt "1" ]; then
    echo "FAIL: unrelated() should be a cache hit, but got 0 hits"
    exit 1
fi

###############################################################################
# Test 2: Call chain invalidation
###############################################################################

cat > "$WORK_DIR/chain.d" << 'EOF'
int leaf() { return 5; }
int middle() { return leaf() + 1; }
int top() { return middle() + 1; }
int standalone() { return 42; }

int main() { return top(); }
EOF

# First compile
"$COMPILER" "$WORK_DIR/chain.d" -o "$WORK_DIR/chain.wasm" --backend="$BACKEND" --cache="$WORK_DIR/cache2" --json > /dev/null

# Verify: top = 5 + 1 + 1 = 7
R4=$(wasm3 --func _D5chain4mainFZi "$WORK_DIR/chain.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$R4" != "7" ]; then
    echo "FAIL: Expected 7, got $R4"
    exit 1
fi

# Change leaf()
cat > "$WORK_DIR/chain.d" << 'EOF'
int leaf() { return 100; }
int middle() { return leaf() + 1; }
int top() { return middle() + 1; }
int standalone() { return 42; }

int main() { return top(); }
EOF

OUT5=$("$COMPILER" "$WORK_DIR/chain.d" -o "$WORK_DIR/chain.wasm" --backend="$BACKEND" --cache="$WORK_DIR/cache2" --json)
HITS5=$(echo "$OUT5" | grep -o '"cacheHits": [0-9]*' | grep -o '[0-9]*')

# Verify: top = 100 + 1 + 1 = 102
R5=$(wasm3 --func _D5chain4mainFZi "$WORK_DIR/chain.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$R5" != "102" ]; then
    echo "FAIL: Expected 102 after leaf change, got $R5 (stale cache)"
    exit 1
fi

# standalone() should still be a cache hit
if [ "$HITS5" -lt "1" ]; then
    echo "FAIL: standalone() should be a cache hit"
    exit 1
fi
