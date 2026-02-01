#!/bin/bash
#
# Test Runner for D-to-WASM Compiler
# 
# Runs milestone tests in order, stops at first failure.
# Designed to provide clear feedback for both humans and agents.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$SCRIPT_DIR/tests/milestones"
COMPILER="$SCRIPT_DIR/d2wasm"
BUILD_DIR="$SCRIPT_DIR/.test_build"

# Colors (disabled in agent mode)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

VERBOSE=false
AGENT_MODE=false
SPECIFIC_TEST=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --agent-mode|-a)
            AGENT_MODE=true
            RED=""
            GREEN=""
            YELLOW=""
            BLUE=""
            NC=""
            shift
            ;;
        *)
            SPECIFIC_TEST="$1"
            shift
            ;;
    esac
done

# Ensure build directory exists
mkdir -p "$BUILD_DIR"

# Check for required tools
check_tools() {
    local missing=""
    
    if ! command -v wasm3 &> /dev/null; then
        missing="$missing wasm3"
    fi
    
    if ! command -v wasm2wat &> /dev/null; then
        missing="$missing wasm2wat"
    fi
    
    if [[ -n "$missing" ]]; then
        echo "Missing required tools:$missing"
        echo "Install with: brew install wasm3 wabt"
        exit 1
    fi
}

# Run a single test
run_test() {
    local test_dir="$1"
    local test_name=$(basename "$test_dir")
    local config_file="$test_dir/config.json"
    local test_file="$test_dir/test.d"
    local expected_file="$test_dir/expected.txt"
    
    # Check required files exist
    if [[ ! -f "$config_file" ]]; then
        echo "SKIP: $test_name (no config.json)"
        return 2
    fi
    
    # Parse config
    local test_type=$(jq -r '.type' "$config_file")
    local description=$(jq -r '.description // "No description"' "$config_file")
    
    if $VERBOSE || $AGENT_MODE; then
        echo ""
        echo "═══════════════════════════════════════════════════════════════"
        echo "TEST: $test_name"
        echo "DESC: $description"
        echo "TYPE: $test_type"
        echo "═══════════════════════════════════════════════════════════════"
    fi
    
    local wasm_file="$BUILD_DIR/${test_name}.wasm"
    local wat_file="$BUILD_DIR/${test_name}.wat"
    local actual_output=""
    local expected_output=""
    local result=0
    
    case $test_type in
        "compile_only")
            # Just compile to WASM and validate structure
            if $VERBOSE; then echo "Compiling $test_file..."; fi
            
            if ! "$COMPILER" "$test_file" -o "$wasm_file" 2>"$BUILD_DIR/compile_error.txt"; then
                actual_output=$(cat "$BUILD_DIR/compile_error.txt")
                result=1
            else
                # Validate with wasm2wat
                if ! wasm2wat "$wasm_file" -o "$wat_file" 2>"$BUILD_DIR/wat_error.txt"; then
                    actual_output="wasm2wat failed: $(cat "$BUILD_DIR/wat_error.txt")"
                    result=1
                else
                    actual_output="OK: valid WASM ($(wc -c < "$wasm_file" | tr -d ' ') bytes)"
                fi
            fi
            expected_output=$(cat "$expected_file" 2>/dev/null || echo "OK: valid WASM")
            ;;
            
        "wasm_exec")
            # Compile and execute in wasm3
            local entry=$(jq -r '.entry // "main"' "$config_file")
            local args=$(jq -r '.args // [] | join(" ")' "$config_file")
            
            if $VERBOSE; then echo "Compiling $test_file..."; fi
            
            if ! "$COMPILER" "$test_file" -o "$wasm_file" 2>"$BUILD_DIR/compile_error.txt"; then
                actual_output="Compile error: $(cat "$BUILD_DIR/compile_error.txt")"
                result=1
            else
                if $VERBOSE; then echo "Executing with wasm3 (entry: $entry)..."; fi
                
                if ! actual_output=$(wasm3 --func "$entry" "$wasm_file" $args 2>&1); then
                    actual_output="wasm3 error: $actual_output"
                    result=1
                fi
            fi
            expected_output=$(cat "$expected_file")
            ;;
            
        "ctfe_eval")
            # Compile with CTFE evaluation, check compiler output
            local expected_value=$(jq -r '.expected_value' "$config_file")
            
            if $VERBOSE; then echo "Compiling with CTFE..."; fi
            
            if ! actual_output=$("$COMPILER" --ctfe-eval "$test_file" 2>&1); then
                result=1
            fi
            expected_output="$expected_value"
            ;;
            
        "ctfe_output")
            # CTFE that produces stdout
            if $VERBOSE; then echo "Compiling with CTFE (expecting output)..."; fi
            
            if ! actual_output=$("$COMPILER" --ctfe-run "$test_file" 2>&1); then
                result=1
            fi
            expected_output=$(cat "$expected_file")
            ;;
            
        "compile_error")
            # Should fail to compile with specific error
            if $VERBOSE; then echo "Compiling (expecting error)..."; fi
            
            if "$COMPILER" "$test_file" -o "$wasm_file" 2>"$BUILD_DIR/compile_error.txt"; then
                actual_output="ERROR: Compilation succeeded but should have failed"
                result=1
            else
                actual_output=$(cat "$BUILD_DIR/compile_error.txt")
            fi
            expected_output=$(cat "$expected_file")
            ;;
            
        *)
            echo "Unknown test type: $test_type"
            return 1
            ;;
    esac
    
    # Compare outputs (trim whitespace)
    actual_trimmed=$(echo "$actual_output" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    expected_trimmed=$(echo "$expected_output" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    if [[ "$actual_trimmed" == "$expected_trimmed" ]] && [[ $result -eq 0 ]]; then
        echo -e "${GREEN}PASS${NC}: $test_name"
        return 0
    else
        echo -e "${RED}FAIL${NC}: $test_name"
        
        if $VERBOSE || $AGENT_MODE; then
            echo ""
            echo "test.d:"
            echo "───────"
            cat "$test_file" 2>/dev/null || echo "(no test file)"
            echo ""
            echo "expected:"
            echo "─────────"
            echo "$expected_output"
            echo ""
            echo "actual:"
            echo "───────"
            echo "$actual_output"
            echo ""
        fi
        
        if $AGENT_MODE; then
            echo "═══════════════════════════════════════════════════════════════"
            echo "TASK: Implement what's needed to pass this test."
            echo "═══════════════════════════════════════════════════════════════"
        fi
        
        return 1
    fi
}

# Main
main() {
    check_tools
    
    echo "D-to-WASM Compiler Test Suite"
    echo ""
    
    local tests_run=0
    local tests_passed=0
    local first_failure=""
    
    # Get sorted list of test directories
    for test_dir in $(ls -d "$TESTS_DIR"/milestone_* 2>/dev/null | sort); do
        test_name=$(basename "$test_dir")
        
        # If specific test requested, skip others
        if [[ -n "$SPECIFIC_TEST" ]] && [[ "$test_name" != *"$SPECIFIC_TEST"* ]]; then
            continue
        fi
        
        ((tests_run++)) || true
        
        if run_test "$test_dir"; then
            ((tests_passed++)) || true
        else
            first_failure="$test_name"
            break  # Stop at first failure
        fi
    done
    
    echo ""
    echo "─────────────────────────────────────────────"
    echo "Results: $tests_passed/$tests_run passed"
    
    if [[ -n "$first_failure" ]]; then
        echo -e "${RED}Stopped at: $first_failure${NC}"
        exit 1
    elif [[ $tests_run -eq 0 ]]; then
        echo -e "${YELLOW}No tests found${NC}"
        exit 0
    else
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    fi
}

main "$@"
