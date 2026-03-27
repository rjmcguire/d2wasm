#!/bin/bash
# Fuzz test runner for D-to-WASM compiler
# Runs all fuzz_*.d files, checks stdout against // EXPECTED: comments
#
# Status markers (first // STATUS: line in file):
#   // STATUS: wontfix     — known limitation, expected to fail
#   // STATUS: maybeLater  — not yet implemented, expected to fail
#   // STATUS: bug         — known bug, expected to fail
#   (no status)            — expected to pass

COMPILER="./d2wasm"
FUZZ_DIR="$(dirname "$0")"
PASS=0
FAIL=0
ERROR=0
KNOWN_FAIL=0
FIXED=0
FAILURES=()
FIXED_LIST=()

for f in "$FUZZ_DIR"/fuzz_*.d; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"

    # Check for status marker
    status="$(grep -m1 '^// STATUS: ' "$f" | awk '{print $3}')"
    expect_fail=false
    if [ "$status" = "wontfix" ] || [ "$status" = "bug" ] || [ "$status" = "maybeLater" ]; then
        expect_fail=true
    fi

    # Extract expected output from // EXPECTED: lines
    expected="$(grep '^// EXPECTED: ' "$f" | sed 's|^// EXPECTED: ||')"

    # Run compiler
    actual="$($COMPILER -r "$f" 2>/dev/null)"
    rc=$?

    # Determine pass/fail
    if [ $rc -ne 0 ]; then
        test_passed=false
    elif [ "$actual" = "$expected" ]; then
        test_passed=true
    else
        test_passed=false
    fi

    if $test_passed; then
        if $expect_fail; then
            # Was expected to fail but now passes — flag it
            FIXED=$((FIXED + 1))
            FIXED_LIST+=("FIXED $name (status=$status but now passes — remove status marker)")
        fi
        PASS=$((PASS + 1))
    else
        if $expect_fail; then
            # Expected to fail, did fail — that's a known failure (counts as pass)
            KNOWN_FAIL=$((KNOWN_FAIL + 1))
            PASS=$((PASS + 1))
        else
            # Unexpected failure
            if [ $rc -ne 0 ]; then
                ERROR=$((ERROR + 1))
                FAILURES+=("COMPILE_ERROR $name (exit $rc)")
            else
                FAIL=$((FAIL + 1))
                FAILURES+=("WRONG_OUTPUT $name")
            fi
            if [ "${VERBOSE:-0}" = "1" ]; then
                echo "--- $name ---"
                echo "expected: $(echo "$expected" | head -3)"
                echo "actual:   $(echo "$actual" | head -3)"
            fi
        fi
    fi
done

TOTAL=$((PASS + FAIL + ERROR))
echo "===== Fuzz Test Results ====="
echo "Total:  $TOTAL"
echo "Pass:   $PASS ($KNOWN_FAIL known failures)"
echo "Fail:   $FAIL"
echo "Error:  $ERROR"

if [ ${#FIXED_LIST[@]} -gt 0 ]; then
    echo ""
    echo "Newly fixed (update status markers):"
    for f in "${FIXED_LIST[@]}"; do
        echo "  $f"
    done
fi

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
