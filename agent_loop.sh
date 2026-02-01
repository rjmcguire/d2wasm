#!/bin/bash
#
# Agent Development Loop
#
# Runs tests, spawns an agent on failure, waits for completion, repeats.
# This automates the TDD cycle with AI agents.
#
# Usage:
#   ./agent_loop.sh                    # Run until all tests pass or max iterations
#   ./agent_loop.sh --max-iterations 5 # Limit iterations
#   ./agent_loop.sh --dry-run          # Show what would be done without spawning
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_RUNNER="$SCRIPT_DIR/test_runner.sh"
BUILD_DIR="$SCRIPT_DIR/.test_build"
LOG_DIR="$SCRIPT_DIR/.agent_logs"

MAX_ITERATIONS=20
DRY_RUN=false
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --max-iterations)
            MAX_ITERATIONS="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

mkdir -p "$LOG_DIR"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[agent_loop]${NC} $1"
}

error() {
    echo -e "${RED}[agent_loop]${NC} $1"
}

success() {
    echo -e "${GREEN}[agent_loop]${NC} $1"
}

# Run tests and capture results
run_tests() {
    log "Running test suite..."
    
    local output
    local exit_code
    
    output=$("$TEST_RUNNER" --agent-mode 2>&1) || exit_code=$?
    
    echo "$output" > "$LOG_DIR/last_test_run.txt"
    
    if [[ -z "$exit_code" ]] || [[ "$exit_code" -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

# Extract failing test info from test output
get_failure_info() {
    local output="$1"
    
    # Extract test name
    FAILING_TEST=$(echo "$output" | grep "^FAIL:" | head -1 | sed 's/FAIL: //')
    
    if [[ -z "$FAILING_TEST" ]]; then
        return 1
    fi
    
    # Get the test directory
    TEST_DIR="$SCRIPT_DIR/tests/milestones/$FAILING_TEST"
    
    # Read test file
    TEST_CODE=$(cat "$TEST_DIR/test.d" 2>/dev/null || echo "(no test.d)")
    
    # Read config
    TEST_DESC=$(jq -r '.description // "No description"' "$TEST_DIR/config.json" 2>/dev/null || echo "No description")
    TEST_TYPE=$(jq -r '.type // "unknown"' "$TEST_DIR/config.json" 2>/dev/null || echo "unknown")
    TEST_CAPABILITY=$(jq -r '.capability // "unknown"' "$TEST_DIR/config.json" 2>/dev/null || echo "unknown")
    
    # Get generated WAT if exists
    GENERATED_WAT=""
    if [[ -f "$BUILD_DIR/${FAILING_TEST}.wat" ]]; then
        GENERATED_WAT=$(cat "$BUILD_DIR/${FAILING_TEST}.wat")
    fi
    
    # Extract actual vs expected from output
    ACTUAL_OUTPUT=$(echo "$output" | sed -n '/^actual:/,/^$/p' | tail -n +2)
    EXPECTED_OUTPUT=$(echo "$output" | sed -n '/^expected:/,/^actual:/p' | tail -n +2 | head -n -1)
    
    return 0
}

# Build the agent task prompt
build_agent_prompt() {
    cat << EOF
You are working on the D-to-WASM compiler project at ~/projects/d-to-wasm-compiler.

## Your Task
Fix the failing test: **$FAILING_TEST**

## Test Information
- **Description:** $TEST_DESC
- **Type:** $TEST_TYPE  
- **Capability being tested:** $TEST_CAPABILITY

## Test Code (test.d)
\`\`\`d
$TEST_CODE
\`\`\`

## Expected Output
\`\`\`
$EXPECTED_OUTPUT
\`\`\`

## Actual Output
\`\`\`
$ACTUAL_OUTPUT
\`\`\`
EOF

    if [[ -n "$GENERATED_WAT" ]]; then
        cat << EOF

## Generated WAT (if relevant)
\`\`\`wat
$GENERATED_WAT
\`\`\`
EOF
    fi

    cat << EOF

## Instructions

1. **Understand the problem:** Read the test code and compare expected vs actual output
2. **Find the relevant code:** Look in src/ for the codegen or parsing logic
3. **Implement the fix:** Make the minimal change needed to pass this test
4. **Verify:** Run ./test_runner.sh to confirm the test passes
5. **Check for regression:** Make sure all previous tests still pass
6. **Test generalization:** Try a variant with different values/names to ensure no overfitting

## Important Principles (from DEVELOPMENT.md)

- **No overfitting:** The fix must work for ANY valid D code of this pattern, not just this test
- **No hardcoding:** Don't check for specific function names, values, or test content
- **Generalization:** After fixing, manually try a variant (different names, different values)

## Project Structure
- src/main.d - Entry point
- src/parser/ - Tree-sitter based parsing
- src/ast/ - AST node definitions  
- src/semantic/ - Type checking, symbol tables
- src/codegen/ - WASM code generation
- notes/ - Architecture documentation

## When Done
Report:
1. What was the root cause?
2. What did you change?
3. Did all tests pass (including previous ones)?
4. Did you verify with a variant to prevent overfitting?
EOF
}

# Spawn an agent (this outputs a command for external orchestration)
spawn_agent() {
    local prompt="$1"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local prompt_file="$LOG_DIR/prompt_${FAILING_TEST}_${timestamp}.md"
    
    # Save prompt
    echo "$prompt" > "$prompt_file"
    
    log "Saved agent prompt to: $prompt_file"
    
    if $DRY_RUN; then
        log "[DRY RUN] Would spawn agent for: $FAILING_TEST"
        echo ""
        echo "═══════════════════════════════════════════════════════════════"
        echo "AGENT PROMPT PREVIEW:"
        echo "═══════════════════════════════════════════════════════════════"
        head -50 "$prompt_file"
        echo "..."
        echo "═══════════════════════════════════════════════════════════════"
        return 0
    fi
    
    # Output the prompt for the orchestrator to use
    echo "SPAWN_AGENT:$prompt_file"
}

# Main loop
main() {
    log "Starting agent development loop"
    log "Max iterations: $MAX_ITERATIONS"
    echo ""
    
    local iteration=0
    
    while [[ $iteration -lt $MAX_ITERATIONS ]]; do
        ((iteration++))
        
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "Iteration $iteration of $MAX_ITERATIONS"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        if run_tests; then
            success "All tests passed! 🎉"
            exit 0
        fi
        
        local test_output=$(cat "$LOG_DIR/last_test_run.txt")
        
        if ! get_failure_info "$test_output"; then
            error "Could not parse failure information"
            exit 1
        fi
        
        log "Failing test: $FAILING_TEST"
        log "Description: $TEST_DESC"
        
        local prompt=$(build_agent_prompt)
        
        spawn_agent "$prompt"
        
        if $DRY_RUN; then
            log "[DRY RUN] Would wait for agent completion, then loop"
            exit 0
        fi
        
        # In non-dry-run mode, we output SPAWN_AGENT and exit
        # The external orchestrator should:
        # 1. Read the prompt file
        # 2. Spawn the agent
        # 3. Wait for completion
        # 4. Re-run this script
        
        log "Agent prompt generated. Waiting for external orchestration..."
        log "Re-run this script after agent completes."
        exit 2  # Special exit code meaning "agent spawned, re-run after completion"
    done
    
    error "Max iterations ($MAX_ITERATIONS) reached without all tests passing"
    exit 1
}

main "$@"
