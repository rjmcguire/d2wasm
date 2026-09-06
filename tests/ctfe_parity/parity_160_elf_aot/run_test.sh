#!/bin/bash
# Native AOT: --target=native produces a linked executable (ELF on Linux).
# Args: $1 = CTFE backend (wasm|native), $2 = compiler path

set -e

BACKEND="${1:?usage: run_test.sh <backend> <compiler>}"
COMPILER="${2:?usage: run_test.sh <backend> <compiler>}"
WORK_DIR=$(mktemp -d)
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

TEST_D="$WORK_DIR/test.d"
cat > "$TEST_D" << 'EOF'
int add(int a, int b) {
    return a + b;
}

int main() {
    return add(40, 2);
}
EOF

OUT="$WORK_DIR/out"
OBJ="$WORK_DIR/out.o"

"$COMPILER" --backend="$BACKEND" --target=native -o "$OUT" "$TEST_D"

if [ ! -x "$OUT" ]; then
    echo "FAIL: expected executable at $OUT"
    exit 1
fi

set +e
"$OUT"
STATUS=$?
set -e
if [ "$STATUS" != "42" ]; then
    echo "FAIL: expected exit 42, got $STATUS"
    exit 1
fi

"$COMPILER" --backend="$BACKEND" --target=native -c -o "$OBJ" "$TEST_D"
if [ ! -f "$OBJ" ]; then
    echo "FAIL: -c did not produce $OBJ"
    exit 1
fi

if [ "$(uname)" = "Linux" ]; then
    if ! file "$OBJ" | grep -q ELF; then
        echo "FAIL: object is not ELF:"
        file "$OBJ"
        exit 1
    fi
    if command -v readelf >/dev/null 2>&1; then
        if ! readelf -h "$OBJ" | grep -q REL; then
            echo "FAIL: ELF object is not ET_REL"
            readelf -h "$OBJ"
            exit 1
        fi
        if ! readelf -s "$OBJ" | grep -q 'main'; then
            echo "FAIL: no main symbol in object"
            readelf -s "$OBJ"
            exit 1
        fi
    fi
    if ! file "$OUT" | grep -q ELF; then
        echo "FAIL: executable is not ELF:"
        file "$OUT"
        exit 1
    fi
fi
