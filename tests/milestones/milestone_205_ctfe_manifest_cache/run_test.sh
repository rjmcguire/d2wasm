#!/bin/bash
# Test: CTFE manifest cache across compilations
#
# Verifies that manifest constant CTFE results are cached to disk and
# restored on the next compile when dependencies are unchanged.
#
# Scenarios:
#   1. First compile: CTFE runs (no cache exists) — result is correct
#   2. Same source: CTFE skipped (cache hit) — result still correct
#   3. Change ctfeHelper: dependent manifest re-evaluated — result updated
#   4. Cache file exists on disk after compilation

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPILER="$SCRIPT_DIR/../../../d2wasm"
WORK_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

###############################################################################
# Test 1: First compile — CTFE runs, correct result
###############################################################################
echo "Test 1: First compile (CTFE runs, cache miss)..."

cat > "$WORK_DIR/cached.d" << 'EOF'
int ctfeHelper() { return 10; }
enum CONST = ctfeHelper();

int consumer() { return CONST + 1; }
int unrelated() { return 99; }

int main() { return consumer(); }
EOF

# First compile with --cache (enables both WASM code cache and manifest CTFE cache)
OUT1=$("$COMPILER" "$WORK_DIR/cached.d" -o "$WORK_DIR/cached.wasm" --cache="$WORK_DIR/cache" --json)

# Verify correctness: consumer() = CONST + 1 = 10 + 1 = 11
R1=$(wasm3 --func _D6cached4mainFZi "$WORK_DIR/cached.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$R1" != "11" ]; then
    echo "FAIL: Expected result 11, got '$R1'"
    exit 1
fi
echo "  OK: result=$R1 (correct)"

# Verify cache files were created
if [ ! -f "$WORK_DIR/cache/cached_ctfe_cache.bin" ]; then
    echo "FAIL: Manifest cache file not created"
    exit 1
fi
if [ ! -f "$WORK_DIR/cache/cached_dep_graph.bin" ]; then
    echo "FAIL: Dep graph file not created"
    exit 1
fi
echo "  OK: cache files created"

###############################################################################
# Test 2: Same source — cached manifest restored, CTFE skipped
###############################################################################
echo "Test 2: Second compile (same source, cache hit)..."

OUT2=$("$COMPILER" "$WORK_DIR/cached.d" -o "$WORK_DIR/cached.wasm" --cache="$WORK_DIR/cache" --json)

# Verify correctness: still 11
R2=$(wasm3 --func _D6cached4mainFZi "$WORK_DIR/cached.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$R2" != "11" ]; then
    echo "FAIL: Expected result 11 on second compile, got '$R2'"
    exit 1
fi
echo "  OK: result=$R2 (correct after cache hit)"

###############################################################################
# Test 3: Change ctfeHelper — dependent manifests re-evaluated
###############################################################################
echo "Test 3: Change ctfeHelper (cache invalidated)..."

cat > "$WORK_DIR/cached.d" << 'EOF'
int ctfeHelper() { return 20; }
enum CONST = ctfeHelper();

int consumer() { return CONST + 1; }
int unrelated() { return 99; }

int main() { return consumer(); }
EOF

OUT3=$("$COMPILER" "$WORK_DIR/cached.d" -o "$WORK_DIR/cached.wasm" --cache="$WORK_DIR/cache" --json)

# Verify correctness: consumer() = 20 + 1 = 21
R3=$(wasm3 --func _D6cached4mainFZi "$WORK_DIR/cached.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$R3" != "21" ]; then
    echo "FAIL: Expected result 21 after ctfeHelper change, got '$R3'"
    echo "  (stale cache: manifest was not re-evaluated)"
    exit 1
fi
echo "  OK: result=$R3 (correctly re-evaluated)"

###############################################################################
# Test 4: Verify fourth compile with new value caches correctly
###############################################################################
echo "Test 4: Fourth compile (new value cached)..."

OUT4=$("$COMPILER" "$WORK_DIR/cached.d" -o "$WORK_DIR/cached.wasm" --cache="$WORK_DIR/cache" --json)

R4=$(wasm3 --func _D6cached4mainFZi "$WORK_DIR/cached.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$R4" != "21" ]; then
    echo "FAIL: Expected result 21 on fourth compile, got '$R4'"
    exit 1
fi
echo "  OK: result=$R4 (cached correctly)"

echo "All CTFE manifest cache tests passed!"
