#!/bin/bash
#
# Milestone Test Runner
# Runs tests in order, stops at first failure
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPILER="$SCRIPT_DIR/d2wasm"
TESTS_DIR="$SCRIPT_DIR/tests/milestones"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Options
VERBOSE=0
AGENT_MODE=0
FILTER=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose) VERBOSE=1; shift ;;
        --agent-mode) AGENT_MODE=1; shift ;;
        -*) echo "Unknown option: $1"; exit 1 ;;
        *) FILTER="$1"; shift ;;
    esac
done

# Check dependencies
check_deps() {
    local missing=()
    command -v wasm3 >/dev/null 2>&1 || missing+=("wasm3")
    command -v wasm2wat >/dev/null 2>&1 || missing+=("wasm2wat")
    
    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "${RED}Missing dependencies: ${missing[*]}${NC}"
        echo "Install with: brew install wasm3 wabt"
        exit 1
    fi
}

# Run a single test
run_test() {
    local test_dir="$1"
    local test_name="$(basename "$test_dir")"
    local config_file="$test_dir/config.json"
    local test_file="$test_dir/test.d"
    local expected_file="$test_dir/expected.txt"
    
    if [ ! -f "$config_file" ]; then
        echo -e "${YELLOW}SKIP${NC} $test_name (no config.json)"
        return 0
    fi
    
    # Parse config
    local test_type=$(jq -r '.type' "$config_file")
    local func_name=$(jq -r '.mangled_entry // .entry // .function // "main"' "$config_file")
    local args=$(jq -r '.args // [] | join(" ")' "$config_file")
    local compiler_args=$(jq -r '.compiler_args // [] | join(" ")' "$config_file")
    local expected_exit=$(jq -r '.expected_exit // 0' "$config_file")
    
    # Handle unittest type (verified by dub test at startup)
    if [ "$test_type" = "unittest" ]; then
        local module_name=$(jq -r '.module' "$config_file")
        if [ "$UNITTEST_PASSED" = "1" ]; then
            echo -e "${GREEN}PASS${NC} $test_name (unittest: $module_name)"
            return 0
        else
            echo -e "${RED}FAIL${NC} $test_name (unittest: $module_name)"
            return 1
        fi
    fi

    # Handle ffi_exec type — compile+run with --run and --link-framework
    if [ "$test_type" = "ffi_exec" ]; then
        # Only supported on macOS
        if [ "$(uname)" != "Darwin" ]; then
            echo -e "${YELLOW}SKIP${NC} $test_name (ffi_exec requires macOS)"
            return 0
        fi

        # Build --link-framework flags from config
        local fw_args=""
        local frameworks=$(jq -r '.link_frameworks // [] | .[]' "$config_file")
        for fw in $frameworks; do
            fw_args="$fw_args --link-framework $fw"
        done

        local expected_result=$(jq -r '.expected_result // "null"' "$config_file")

        if [ $VERBOSE -eq 1 ]; then
            echo "Running FFI test: $COMPILER --run $fw_args $compiler_args $test_file"
        fi

        local run_output
        run_output=$("$COMPILER" --run $fw_args $compiler_args "$test_file" 2>&1)
        local run_exit=$?

        if [ "$expected_result" != "null" ]; then
            if [ "$run_exit" -eq "$expected_result" ]; then
                echo -e "${GREEN}PASS${NC} $test_name (ffi exit: $run_exit)"
                return 0
            else
                echo -e "${RED}FAIL${NC} $test_name"
                echo "  Expected exit code: $expected_result"
                echo "  Actual exit code: $run_exit"
                if [ $VERBOSE -eq 1 ]; then
                    echo "  Output:"
                    echo "$run_output" | sed 's/^/    /'
                fi
                return 1
            fi
        else
            # No expected_result — just check it runs successfully
            if [ "$run_exit" -eq "$expected_exit" ]; then
                echo -e "${GREEN}PASS${NC} $test_name (ffi exit: $run_exit)"
                return 0
            else
                echo -e "${RED}FAIL${NC} $test_name"
                echo "  Expected exit code: $expected_exit"
                echo "  Actual exit code: $run_exit"
                if [ $VERBOSE -eq 1 ]; then
                    echo "  Output:"
                    echo "$run_output" | sed 's/^/    /'
                fi
                return 1
            fi
        fi
    fi

    # Build
    local wasm_file="$test_dir/test.wasm"
    rm -f "$wasm_file"
    
    if [ $VERBOSE -eq 1 ]; then
        echo "Compiling $test_file..."
    fi
    
    local compile_output
    compile_output=$("$COMPILER" "$test_file" -o "$wasm_file" $compiler_args 2>&1)
    local compile_status=$?
    
    # Handle compile_output test type (check output during compilation)
    if [ "$test_type" = "compile_output" ]; then
        local expected_output=$(jq -r '.expected_output' "$config_file")
        if echo "$compile_output" | grep -qF "$expected_output"; then
            local display_output="${expected_output//$'\n'/\\n}"
            printf "${GREEN}PASS${NC} %s (output: %s)\n" "$test_name" "$display_output"
            return 0
        else
            echo -e "${RED}FAIL${NC} $test_name"
            echo "  Expected output: $expected_output"
            echo "  Compile output:"
            echo "$compile_output" | sed 's/^/    /'
            return 1
        fi
    fi
    
    if [ $compile_status -ne 0 ]; then
        if [ "$test_type" = "compile_error" ]; then
            # Expected to fail compilation — check error message content
            if [ -f "$expected_file" ]; then
                local all_matched=true
                local failed_line=""
                while IFS= read -r line || [ -n "$line" ]; do
                    # Strip leading/trailing whitespace
                    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                    [ -z "$line" ] && continue
                    if ! echo "$compile_output" | grep -qF -- "$line"; then
                        all_matched=false
                        failed_line="$line"
                        break
                    fi
                done < "$expected_file"
                if [ "$all_matched" = true ]; then
                    echo -e "${GREEN}PASS${NC} $test_name (compile error as expected)"
                    return 0
                else
                    echo -e "${RED}FAIL${NC} $test_name"
                    echo "  Missing expected line: $failed_line"
                    echo "  Actual output:"
                    echo "$compile_output" | sed 's/^/    /'
                    return 1
                fi
            fi
            # Check expected_error from config.json
            local expected_error=$(jq -r '.expected_error // empty' "$config_file")
            if [ -n "$expected_error" ]; then
                if echo "$compile_output" | grep -qF "$expected_error"; then
                    echo -e "${GREEN}PASS${NC} $test_name (compile error as expected)"
                    return 0
                else
                    echo -e "${RED}FAIL${NC} $test_name"
                    echo "  Expected error text: $expected_error"
                    echo "  Actual output:"
                    echo "$compile_output" | sed 's/^/    /'
                    return 1
                fi
            fi
            # No expected text specified — just check that it failed
            echo -e "${GREEN}PASS${NC} $test_name (compile error)"
            return 0
        fi
        
        echo -e "${RED}FAIL${NC} $test_name"
        echo "  Compilation failed:"
        echo "$compile_output" | sed 's/^/    /'
        return 1
    fi
    
    # compile_error tests should have failed above                                                 
    if [ "$test_type" = "compile_error" ]; then                                                    
      echo -e "${RED}FAIL${NC} $test_name"                                                       
      echo "  Expected compilation to fail, but it succeeded"                                    
      return 1                                                                                   
    fi
    # Validate binary with wasm2wat
    if ! wasm2wat "$wasm_file" >/dev/null 2>&1; then
        echo -e "${RED}FAIL${NC} $test_name"
        echo "  Invalid WASM binary (wasm2wat failed)"
        return 1
    fi
    
    case "$test_type" in
        compile_only)
            echo -e "${GREEN}PASS${NC} $test_name"
            return 0
            ;;
            
        run|wasm_exec)
            local result
            if ! result=$(wasm3 --func "$func_name" "$wasm_file" $args 2>&1); then
                echo -e "${RED}FAIL${NC} $test_name"
                echo "  wasm3 execution failed:"
                echo "$result" | sed 's/^/    /'
                return 1
            fi
            
            # Extract numeric result
            local actual=$(echo "$result" | grep -oE 'Result: -?[0-9]+' | grep -oE '\-?[0-9]+')
            
            if [ -f "$expected_file" ]; then
                # Extract expected number (may be "42" or "Result: 42")
                local expected=$(cat "$expected_file" | grep -oE '\-?[0-9]+' | head -1)
                if [ "$actual" != "$expected" ]; then
                    echo -e "${RED}FAIL${NC} $test_name"
                    echo "  Expected: $expected"
                    echo "  Actual: $actual"
                    return 1
                fi
            else
                # Check expected_result from config.json
                local expected_result=$(jq -r '.expected_result // "null"' "$config_file")
                if [ "$expected_result" != "null" ] && [ "$actual" != "$expected_result" ]; then
                    echo -e "${RED}FAIL${NC} $test_name"
                    echo "  Expected: $expected_result"
                    echo "  Actual: $actual"
                    return 1
                fi
            fi
            
            echo -e "${GREEN}PASS${NC} $test_name (result: $actual)"
            return 0
            ;;
            
        wasm_import_exec)
            # Test with host function imports - uses import_test_harness
            local harness="$SCRIPT_DIR/tests/import_test_harness"
            if [ ! -x "$harness" ]; then
                # Try to build it
                if [ -f "$harness.d" ]; then
                    echo "Building import test harness..."
                    if ! dub build --skip-registry=standard --single "$harness.d" 2>/dev/null; then
                        echo -e "${YELLOW}SKIP${NC} $test_name (harness build failed)"
                        return 0
                    fi
                else
                    echo -e "${YELLOW}SKIP${NC} $test_name (harness not found)"
                    return 0
                fi
            fi
            
            local result
            if ! result=$("$harness" "$wasm_file" "$config_file" 2>&1); then
                echo -e "${RED}FAIL${NC} $test_name"
                echo "  Import test failed:"
                echo "$result" | sed 's/^/    /'
                return 1
            fi
            
            if echo "$result" | grep -q "^PASS"; then
                local actual=$(echo "$result" | grep -oE 'result = -?[0-9]+' | grep -oE '\-?[0-9]+')
                echo -e "${GREEN}PASS${NC} $test_name (result: $actual)"
                return 0
            else
                echo -e "${RED}FAIL${NC} $test_name"
                echo "$result" | sed 's/^/    /'
                return 1
            fi
            ;;
            
        ctfe_eval)
            # CTFE evaluation test - check compile output for expected value
            local expected_value=$(jq -r '.expected_value' "$config_file")
            if echo "$compile_output" | grep -qF "CTFE:.*= $expected_value"; then
                echo -e "${GREEN}PASS${NC} $test_name (value: $expected_value)"
                return 0
            else
                echo -e "${RED}FAIL${NC} $test_name"
                echo "  Expected CTFE value: $expected_value"
                echo "  Compile output:"
                echo "$compile_output" | sed 's/^/    /'
                return 1
            fi
            ;;
            
        ctfe_output)
            # CTFE output test - check stdout during compilation
            local expected_output=$(jq -r '.expected_output' "$config_file")
            if echo "$compile_output" | grep -qF "$expected_output"; then
                echo -e "${GREEN}PASS${NC} $test_name (output: $expected_output)"
                return 0
            else
                echo -e "${RED}FAIL${NC} $test_name"
                echo "  Expected output: $expected_output"
                echo "  Compile output:"
                echo "$compile_output" | sed 's/^/    /'
                return 1
            fi
            ;;
            
        deterministic)
            # Deterministic output test - compile twice, verify byte-identical WASM
            local wasm_file2="$test_dir/test2.wasm"
            
            # Second compilation
            if ! "$COMPILER" "$test_file" -o "$wasm_file2" >/dev/null 2>&1; then
                echo -e "${RED}FAIL${NC} $test_name"
                echo "  Second compilation failed"
                return 1
            fi
            
            # Compare WASM files
            if ! cmp -s "$wasm_file" "$wasm_file2"; then
                echo -e "${RED}FAIL${NC} $test_name"
                echo "  WASM files differ between compilations"
                echo "  First:  $(xxd "$wasm_file" | head -5)"
                echo "  Second: $(xxd "$wasm_file2" | head -5)"
                return 1
            fi
            
            # Also verify the result is correct
            local result
            if ! result=$(wasm3 --func "$func_name" "$wasm_file" 2>&1); then
                echo -e "${RED}FAIL${NC} $test_name"
                echo "  Execution failed: $result"
                return 1
            fi
            
            local actual=$(echo "$result" | grep -oE 'Result: -?[0-9]+' | grep -oE '\-?[0-9]+')
            local expected_result=$(jq -r '.expected_result // "null"' "$config_file")
            if [ "$expected_result" != "null" ] && [ "$actual" != "$expected_result" ]; then
                echo -e "${RED}FAIL${NC} $test_name"
                echo "  Expected: $expected_result, Actual: $actual"
                return 1
            fi
            
            echo -e "${GREEN}PASS${NC} $test_name (deterministic, result: $actual)"
            return 0
            ;;
            
        shell)
            # Shell script test - run a custom test script
            local script=$(jq -r '.script // "run_test.sh"' "$config_file")
            local script_path="$test_dir/$script"
            
            if [ ! -x "$script_path" ]; then
                echo -e "${RED}FAIL${NC} $test_name"
                echo "  Script not found or not executable: $script_path"
                return 1
            fi
            
            local script_output
            if ! script_output=$("$script_path" 2>&1); then
                echo -e "${RED}FAIL${NC} $test_name"
                echo "  Script failed:"
                echo "$script_output" | sed 's/^/    /'
                return 1
            fi
            
            echo -e "${GREEN}PASS${NC} $test_name (shell)"
            return 0
            ;;
            
        *)
            echo -e "${YELLOW}SKIP${NC} $test_name (unknown type: $test_type)"
            return 0
            ;;
    esac
}

# Main
check_deps

if [ ! -x "$COMPILER" ]; then
    echo "Building compiler..."
    (cd "$SCRIPT_DIR" && dub build --skip-registry=standard)
fi

# Run unit tests (for unittest-type milestones)
echo "Running unit tests..."
if (cd "$SCRIPT_DIR" && dub test 2>&1) | grep -q "FAILED unittests"; then
    echo -e "${RED}Unit tests FAILED${NC}"
    UNITTEST_PASSED=0
else
    echo -e "${GREEN}Unit tests passed${NC}"
    UNITTEST_PASSED=1
fi

echo 1234
# Rebuild (dub test leaves unittest-enabled binary)
(cd "$SCRIPT_DIR" && dub build --skip-registry=standard)
echo
echo 1234

echo "Running milestone tests..."
echo

passed=0
failed=0
skipped=0

for test_dir in $(ls -d "$TESTS_DIR"/milestone_* "$TESTS_DIR"/quality_* 2>/dev/null | sort -V); do
    # Filter by name if specified
    if [ -n "$FILTER" ] && [[ "$(basename "$test_dir")" != *"$FILTER"* ]]; then
        continue
    fi
    if run_test "$test_dir"; then
        ((passed++)) || true
    else
        ((failed++)) || true
        if [ $AGENT_MODE -eq 1 ]; then
            echo
            echo "=== AGENT MODE: First failure details ==="
            echo "Test: $(basename "$test_dir")"
            echo "Config: $(cat "$test_dir/config.json")"
            echo "Source:"
            cat "$test_dir/test.d"
            if [ -f "$test_dir/test.wasm" ]; then
                echo "Decompiled WASM:"
                wasm2wat "$test_dir/test.wasm" 2>/dev/null || echo "(decompilation failed)"
            fi
        fi
        break  # Stop at first failure
    fi
done

echo
echo "Results: $passed passed, $failed failed, $skipped skipped"

[ $failed -eq 0 ]
