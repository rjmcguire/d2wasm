#!/bin/bash
# Fuzz test runner for D-to-WASM compiler
# Runs all fuzz_*.d files, checks stdout against // EXPECTED: comments
#
# Status markers (first // STATUS: line in file):
#   // STATUS: wontfix     — known limitation, won't be fixed
#   // STATUS: maybeLater  — not yet implemented, may be added
#   // STATUS: bug         — known bug, tracked for fixing
#   (no status)            — expected to pass

COMPILER="./d2wasm"
FUZZ_DIR="$(dirname "$0")"
PASS=0
FAIL=0
ERROR=0
SKIP_WONTFIX=0
SKIP_MAYBELATER=0
SKIP_BUG=0
FAILURES=()

for f in "$FUZZ_DIR"/fuzz_*.d; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"

    # Check for status marker
    status="$(grep -m1 '^// STATUS: ' "$f" | awk '{print $3}')"

    case "$status" in
        wontfix)
            SKIP_WONTFIX=$((SKIP_WONTFIX + 1))
            continue
            ;;
        maybeLater)
            SKIP_MAYBELATER=$((SKIP_MAYBELATER + 1))
            continue
            ;;
        bug)
            SKIP_BUG=$((SKIP_BUG + 1))
            continue
            ;;
    esac

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
SKIPPED=$((SKIP_WONTFIX + SKIP_MAYBELATER + SKIP_BUG))
echo "===== Fuzz Test Results ====="
echo "Total:  $((TOTAL + SKIPPED))"
echo "Run:    $TOTAL"
echo "Pass:   $PASS"
echo "Fail:   $FAIL"
echo "Error:  $ERROR"
echo "Skipped: $SKIPPED (wontfix=$SKIP_WONTFIX, maybeLater=$SKIP_MAYBELATER, bug=$SKIP_BUG)"

if [ ${#FAILURES[@]} -gt 0 ]; then
    echo ""
    echo "Failures:"
    for f in "${FAILURES[@]}"; do
        echo "  $f"
    done
    exit 1
fi

echo "All run tests passed!"
exit 0
