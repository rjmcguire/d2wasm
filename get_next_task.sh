#!/bin/bash
#
# Get Next Task
#
# Runs the test suite and outputs the next failing test as a structured prompt
# suitable for spawning an agent.
#
# Exit codes:
#   0 - All tests pass
#   1 - Error
#   2 - Task available (prompt written to stdout)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_RUNNER="$SCRIPT_DIR/test_runner.sh"
BUILD_DIR="$SCRIPT_DIR/.test_build"

# Run tests silently
run_tests() {
    "$TEST_RUNNER" 2>&1
}

# Main
main() {
    local output
    local exit_code=0
    
    output=$(run_tests) || exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        echo "ALL_TESTS_PASS"
        exit 0
    fi
    
    # Extract failing test
    local failing_test=$(echo "$output" | grep "Stopped at:" | sed 's/.*Stopped at: //' | tr -d '[:space:]' | sed 's/\x1b\[[0-9;]*m//g')
    
    if [[ -z "$failing_test" ]]; then
        echo "ERROR: Could not determine failing test"
        exit 1
    fi
    
    local test_dir="$SCRIPT_DIR/tests/milestones/$failing_test"
    
    # Get test info
    local test_code=$(cat "$test_dir/test.d" 2>/dev/null || echo "(no test file)")
    local test_desc=$(jq -r '.description // "No description"' "$test_dir/config.json" 2>/dev/null || echo "No description")
    local test_type=$(jq -r '.type // "unknown"' "$test_dir/config.json" 2>/dev/null || echo "unknown")
    local capability=$(jq -r '.capability // "unknown"' "$test_dir/config.json" 2>/dev/null || echo "unknown")
    local expected=$(cat "$test_dir/expected.txt" 2>/dev/null || echo "(no expected.txt)")
    
    # Get generated WAT if exists
    local generated_wat=""
    if [[ -f "$BUILD_DIR/${failing_test}.wat" ]]; then
        generated_wat=$(cat "$BUILD_DIR/${failing_test}.wat")
    fi
    
    # Get actual output from test run
    local actual=$(echo "$output" | sed -n '/^actual:/,/^═/p' | grep -v "^═" | tail -n +2 | head -20)
    
    # Get compile errors if any
    local compile_error=""
    if [[ -f "$BUILD_DIR/compile_error.txt" ]]; then
        compile_error=$(cat "$BUILD_DIR/compile_error.txt" 2>/dev/null)
    fi
    
    # Output structured task
    cat << TASK_END
You are working on the D-to-WASM compiler project at ~/projects/d-to-wasm-compiler.

## Task: Fix failing test **$failing_test**

**Description:** $test_desc
**Type:** $test_type
**Capability:** $capability

### Test Code (test.d)
\`\`\`d
$test_code
\`\`\`

### Expected
\`\`\`
$expected
\`\`\`

### Actual
\`\`\`
$actual
\`\`\`
TASK_END

    if [[ -n "$compile_error" ]]; then
        cat << TASK_END

### Compile Error
\`\`\`
$compile_error
\`\`\`
TASK_END
    fi

    if [[ -n "$generated_wat" ]]; then
        cat << TASK_END

### Generated WAT
\`\`\`wat
$(echo "$generated_wat" | head -60)
\`\`\`
TASK_END
    fi

    cat << TASK_END

## Instructions

1. Run \`./test_runner.sh --verbose $failing_test\` to see full output
2. Find relevant code in src/ (likely src/codegen/ for codegen issues)
3. Implement the fix
4. Run \`./test_runner.sh\` to verify ALL tests pass (no regression)
5. Test with a variant (different names/values) to ensure no overfitting

## Principles
- No hardcoding test values
- Fix must be general, not specific to this test
- Check DEVELOPMENT.md for full guidelines

## When Done
Report: root cause, what changed, tests passing, variant tested.
TASK_END

    exit 2
}

main "$@"
