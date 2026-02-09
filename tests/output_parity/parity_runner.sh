#!/bin/bash
#
# Output Parity Test Runner
# Runs each test with ALL output backends to ensure feature parity
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPILER="$PROJECT_DIR/d2wasm"
TESTS_DIR="$SCRIPT_DIR"

# Output backends that must have feature parity
# Add new backends here as they're implemented (e.g., "native" for ARM64 direct output)
OUTPUT_BACKENDS=(wasm)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Options
VERBOSE=0
STOP_ON_FAIL=0

# Check dependencies
check_deps() {
    local missing=()
    command -v wasm3 >/dev/null 2>&1 || missing+=("wasm3")
    command -v wasm2wat >/dev/null 2>&1 || missing+=("wasm2wat")
    command -v jq >/dev/null 2>&1 || missing+=("jq")
    
    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "${RED}Missing dependencies: ${missing[*]}${NC}"
        echo "Install with: brew install wasm3 wabt jq"
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose) VERBOSE=1; shift ;;
        --stop-on-fail) STOP_ON_FAIL=1; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Run a single test with a specific backend
run_test_with_backend() {
    local test_dir="$1"
    local backend="$2"
    local test_name="$(basename "$test_dir")"
    local config_file="$test_dir/config.json"
    local test_file="$test_dir/test.d"
    
    if [ ! -f "$config_file" ]; then
        echo -e "${YELLOW}SKIP${NC} $test_name [$backend] (no config.json)"
        return 0
    fi
    
    local test_type=$(jq -r '.type' "$config_file")
    
    # Only handle output test types
    case "$test_type" in
        wasm_exec|compile_only) ;;
        *)
            echo -e "${YELLOW}SKIP${NC} $test_name [$backend] (not an output test type: $test_type)"
            return 0
            ;;
    esac
    
    # Build
    local wasm_file="$test_dir/test.wasm"
    rm -f "$wasm_file"
    
    if [ $VERBOSE -eq 1 ]; then
        echo "  Compiling for $backend output..."
    fi
    
    local compile_output
    # For now, output backend selection would be a future flag
    # Currently we just compile normally for WASM output
    compile_output=$("$COMPILER" "$test_file" -o "$wasm_file" 2>&1)
    local compile_status=$?
    
    if [ $compile_status -ne 0 ]; then
        echo -e "${RED}FAIL${NC} $test_name [$backend]"
        echo "  Compilation failed:"
        echo "$compile_output" | sed 's/^/    /'
        return 1
    fi
    
    case "$test_type" in
        compile_only)
            # Just verify it compiles and produces valid output
            if ! wasm2wat "$wasm_file" >/dev/null 2>&1; then
                echo -e "${RED}FAIL${NC} $test_name [$backend]"
                echo "  Invalid WASM binary"
                return 1
            fi
            echo -e "${GREEN}PASS${NC} $test_name [$backend] (compiled)"
            return 0
            ;;
            
        wasm_exec)
            # Validate WASM binary
            if ! wasm2wat "$wasm_file" >/dev/null 2>&1; then
                echo -e "${RED}FAIL${NC} $test_name [$backend]"
                echo "  Invalid WASM binary"
                return 1
            fi
            
            local func_name=$(jq -r '.entry // .function // "main"' "$config_file")
            local args=$(jq -r '.args // [] | join(" ")' "$config_file")
            
            local result
            if ! result=$(wasm3 --func "$func_name" "$wasm_file" $args 2>&1); then
                echo -e "${RED}FAIL${NC} $test_name [$backend]"
                echo "  wasm3 execution failed:"
                echo "$result" | sed 's/^/    /'
                return 1
            fi
            
            local actual=$(echo "$result" | grep -oE 'Result: -?[0-9]+' | grep -oE '\-?[0-9]+')
            local expected_result=$(jq -r '.expected_result // "null"' "$config_file")
            
            if [ "$expected_result" != "null" ] && [ "$actual" != "$expected_result" ]; then
                echo -e "${RED}FAIL${NC} $test_name [$backend]"
                echo "  Expected: $expected_result, Actual: $actual"
                return 1
            fi
            
            echo -e "${GREEN}PASS${NC} $test_name [$backend] (result: $actual)"
            return 0
            ;;
    esac
}

# Run a test across all backends
run_test_all_backends() {
    local test_dir="$1"
    local test_name="$(basename "$test_dir")"
    local all_passed=1
    
    for backend in "${OUTPUT_BACKENDS[@]}"; do
        if ! run_test_with_backend "$test_dir" "$backend"; then
            all_passed=0
            if [ $STOP_ON_FAIL -eq 1 ]; then
                return 1
            fi
        fi
    done
    
    return $((1 - all_passed))
}

# Main
check_deps

echo -e "${CYAN}Output Parity Test Runner${NC}"
echo -e "Backends: ${OUTPUT_BACKENDS[*]}"
echo

if [ ! -x "$COMPILER" ]; then
    echo "Building compiler..."
    (cd "$PROJECT_DIR" && dub build)
fi

passed=0
failed=0

# Find all test directories (excluding the runner script)
for test_dir in $(find "$TESTS_DIR" -mindepth 1 -maxdepth 1 -type d | sort); do
    if run_test_all_backends "$test_dir"; then
        ((passed++)) || true
    else
        ((failed++)) || true
        if [ $STOP_ON_FAIL -eq 1 ]; then
            break
        fi
    fi
done

echo
echo -e "${CYAN}Output Parity Results:${NC} $passed passed, $failed failed"
echo "Backends tested: ${OUTPUT_BACKENDS[*]}"

[ $failed -eq 0 ]
