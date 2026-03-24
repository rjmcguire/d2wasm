#!/bin/bash
# Parity test: CTFE manifest cache across compilations
# Adapted from milestone_205_ctfe_manifest_cache
#
# Scenarios:
#   1. First compile: CTFE runs, correct result
#   2. Same source: cached manifest restored, CTFE skipped
#   3. Change ctfeHelper: dependent manifest re-evaluated
#   4. New value caches correctly
#
# Args: $1 = CTFE backend (wasm|native), $2 = compiler path

set -e

BACKEND="${1:?usage: run_test.sh <backend> <compiler>}"
COMPILER="${2:?usage: run_test.sh <backend> <compiler>}"
WORK_DIR=$(mktemp -d)

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

cat > "$WORK_DIR/cached.d" << 'EOF'
int ctfeHelper() { return 10; }
enum CONST = ctfeHelper();

int consumer() { return CONST + 1; }
int unrelated() { return 99; }

int main() { return consumer(); }
EOF

# Test 1: First compile — CTFE runs, result correct
OUT1=$("$COMPILER" "$WORK_DIR/cached.d" -o "$WORK_DIR/cached.wasm" --backend="$BACKEND" --cache="$WORK_DIR/cache" --json)

R1=$(wasm3 --func _D6cached4mainFZi "$WORK_DIR/cached.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$R1" != "11" ]; then
    echo "FAIL: Expected result 11, got '$R1'"
    exit 1
fi

# Verify cache files were created
if [ ! -f "$WORK_DIR/cache/cached_ctfe_cache.bin" ]; then
    echo "FAIL: Manifest cache file not created"
    exit 1
fi
if [ ! -f "$WORK_DIR/cache/cached_dep_graph.bin" ]; then
    echo "FAIL: Dep graph file not created"
    exit 1
fi

# Test 2: Same source — cached manifest restored
OUT2=$("$COMPILER" "$WORK_DIR/cached.d" -o "$WORK_DIR/cached.wasm" --backend="$BACKEND" --cache="$WORK_DIR/cache" --json)

R2=$(wasm3 --func _D6cached4mainFZi "$WORK_DIR/cached.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$R2" != "11" ]; then
    echo "FAIL: Expected result 11 on second compile, got '$R2'"
    exit 1
fi

# Test 3: Change ctfeHelper — dependent manifest re-evaluated
cat > "$WORK_DIR/cached.d" << 'EOF'
int ctfeHelper() { return 20; }
enum CONST = ctfeHelper();

int consumer() { return CONST + 1; }
int unrelated() { return 99; }

int main() { return consumer(); }
EOF

OUT3=$("$COMPILER" "$WORK_DIR/cached.d" -o "$WORK_DIR/cached.wasm" --backend="$BACKEND" --cache="$WORK_DIR/cache" --json)

R3=$(wasm3 --func _D6cached4mainFZi "$WORK_DIR/cached.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$R3" != "21" ]; then
    echo "FAIL: Expected result 21 after ctfeHelper change, got '$R3' (stale cache)"
    exit 1
fi

# Test 4: Fourth compile — new value cached correctly
OUT4=$("$COMPILER" "$WORK_DIR/cached.d" -o "$WORK_DIR/cached.wasm" --backend="$BACKEND" --cache="$WORK_DIR/cache" --json)

R4=$(wasm3 --func _D6cached4mainFZi "$WORK_DIR/cached.wasm" 2>&1 | grep -o 'Result: [0-9]*' | grep -o '[0-9]*' || true)
if [ "$R4" != "21" ]; then
    echo "FAIL: Expected result 21 on fourth compile, got '$R4'"
    exit 1
fi
