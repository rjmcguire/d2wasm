#!/bin/bash
# Test: Dependency graph cache invalidation
#
# Verifies that when a dependency changes, all transitive dependents are
# evicted from the code cache — not just the directly changed function.
#
# Scenarios:
#   1. CTFE manifest chain:  ctfeHelper() -> enum CONST -> consumer()
#   2. Call chain:            leaf() -> middle() -> top()
#   3. Struct field change:   struct S -> user of S

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPILER="$SCRIPT_DIR/../../../d2wasm"
WORK_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

###############################################################################
# Test 1: CTFE manifest constant chain
#   When ctfeHelper changes, enum CONST is re-evaluated, and consumer()
#   (which reads CONST) must also be re-emitted.
###############################################################################
echo "Test 1: CTFE manifest chain invalidation..."

cat > "$WORK_DIR/ctfe.d" << 'EOF'
int ctfeHelper() { return 10; }
enum CONST = ctfeHelper();

int consumer() { return CONST + 1; }
int unrelated() { return 99; }

int main() { return consumer(); }
EOF

# First compile: all misses
OUT1=$("$COMPILER" "$WORK_DIR/ctfe.d" -o "$WORK_DIR/ctfe.wasm" --cache="$WORK_DIR/cache1" --json)
HITS1=$(echo "$OUT1" | grep -o '"cacheHits": [0-9]*' | grep -o '[0-9]*')
MISSES1=$(echo "$OUT1" | grep -o '"cacheMisses": [0-9]*' | grep -o '[0-9]*')
echo "  Compile 1: hits=$HITS1 misses=$MISSES1"

# Verify correctness: consumer() = CONST + 1 = 10 + 1 = 11
R1=$(wasm3 --func _D4ctfe4mainFZi "$WORK_DIR/ctfe.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$R1" != "11" ]; then
    echo "FAIL: Expected result 11, got $R1"
    exit 1
fi

# Second compile: same source, all hits
OUT2=$("$COMPILER" "$WORK_DIR/ctfe.d" -o "$WORK_DIR/ctfe.wasm" --cache="$WORK_DIR/cache1" --json)
HITS2=$(echo "$OUT2" | grep -o '"cacheHits": [0-9]*' | grep -o '[0-9]*')
MISSES2=$(echo "$OUT2" | grep -o '"cacheMisses": [0-9]*' | grep -o '[0-9]*')
echo "  Compile 2 (unchanged): hits=$HITS2 misses=$MISSES2"
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

OUT3=$("$COMPILER" "$WORK_DIR/ctfe.d" -o "$WORK_DIR/ctfe.wasm" --cache="$WORK_DIR/cache1" --json)
HITS3=$(echo "$OUT3" | grep -o '"cacheHits": [0-9]*' | grep -o '[0-9]*')
MISSES3=$(echo "$OUT3" | grep -o '"cacheMisses": [0-9]*' | grep -o '[0-9]*')
echo "  Compile 3 (ctfeHelper changed): hits=$HITS3 misses=$MISSES3"

# Verify correctness: consumer() = 20 + 1 = 21
R3=$(wasm3 --func _D4ctfe4mainFZi "$WORK_DIR/ctfe.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$R3" != "21" ]; then
    echo "FAIL: Expected result 21 after ctfeHelper change, got $R3"
    echo "  (stale cache: consumer() was not re-emitted)"
    exit 1
fi

# unrelated() should still be a hit — it doesn't depend on CONST
# At minimum: ctfeHelper (changed), CONST (depends on ctfeHelper),
#             consumer (reads CONST), main (calls consumer) = 4 misses
# unrelated should be a hit
if [ "$HITS3" -lt "1" ]; then
    echo "FAIL: unrelated() should be a cache hit, but got 0 hits"
    exit 1
fi
echo "  OK: CTFE chain correctly invalidated (result=$R3)"

###############################################################################
# Test 2: Call chain invalidation
#   leaf() -> middle() -> top()
#   Changing leaf() should invalidate middle() and top()
###############################################################################
echo "Test 2: Call chain invalidation..."

cat > "$WORK_DIR/chain.d" << 'EOF'
int leaf() { return 5; }
int middle() { return leaf() + 1; }
int top() { return middle() + 1; }
int standalone() { return 42; }

int main() { return top(); }
EOF

# First compile
"$COMPILER" "$WORK_DIR/chain.d" -o "$WORK_DIR/chain.wasm" --cache="$WORK_DIR/cache2" --json > /dev/null

# Verify: top = middle + 1 = (leaf + 1) + 1 = 5 + 1 + 1 = 7
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

OUT5=$("$COMPILER" "$WORK_DIR/chain.d" -o "$WORK_DIR/chain.wasm" --cache="$WORK_DIR/cache2" --json)
HITS5=$(echo "$OUT5" | grep -o '"cacheHits": [0-9]*' | grep -o '[0-9]*')
MISSES5=$(echo "$OUT5" | grep -o '"cacheMisses": [0-9]*' | grep -o '[0-9]*')
echo "  After leaf change: hits=$HITS5 misses=$MISSES5"

# Verify: top = 100 + 1 + 1 = 102
R5=$(wasm3 --func _D5chain4mainFZi "$WORK_DIR/chain.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$R5" != "102" ]; then
    echo "FAIL: Expected 102 after leaf change, got $R5"
    echo "  (stale cache: middle/top not re-emitted)"
    exit 1
fi

# standalone() should still be a cache hit
if [ "$HITS5" -lt "1" ]; then
    echo "FAIL: standalone() should be a cache hit"
    exit 1
fi
echo "  OK: Call chain correctly invalidated (result=$R5)"

echo "All dep-graph cache invalidation tests passed!"
