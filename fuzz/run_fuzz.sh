#!/bin/bash
# Fuzz test runner for D-to-WASM compiler
# Runs all fuzz_*.d files, checks stdout against // EXPECTED: comments

COMPILER="./d2wasm"
FUZZ_DIR="$(dirname "$0")"
PASS=0
FAIL=0
ERROR=0
FAILURES=()

for f in "$FUZZ_DIR"/fuzz_*.d; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"

    # Extract expected output from // EXPECTED: lines
    expected="$(grep '^// EXPECTED: ' "$f" | sed 's|^// EXPECTED: ||')"

    # Run compiler
    actual="$($COMPILER -r "$f" 2>/dev/null)"
    rc=$?

    if [ $rc -ne 0 ]; then
        ERROR=$((ERROR + 1))
        FAILURES+=("COMPILE_ERROR $name (exit $rc)")
        continue
    fi

    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILURES+=("WRONG_OUTPUT $name")
        if [ "${VERBOSE:-0}" = "1" ]; then
            echo "--- $name ---"
            echo "expected: $(echo "$expected" | head -3)"
            echo "actual:   $(echo "$actual" | head -3)"
        fi
    fi
done

TOTAL=$((PASS + FAIL + ERROR))
echo "===== Fuzz Test Results ====="
echo "Total:  $TOTAL"
echo "Pass:   $PASS"
echo "Fail:   $FAIL"
echo "Error:  $ERROR"

if [ ${#FAILURES[@]} -gt 0 ]; then
    echo ""
    echo "Failures:"
    for f in "${FAILURES[@]}"; do
        echo "  $f"
    done
    exit 1
fi

echo "All tests passed!"
exit 0
