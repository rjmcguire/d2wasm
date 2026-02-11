#!/bin/bash
#
# CTFE Backend Benchmark
# Compares WASM vs Native backend performance using -vv timing output
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPILER="$PROJECT_DIR/d2wasm"
TESTS_DIR="$SCRIPT_DIR/tests"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

BACKENDS=(wasm native)
ITERATIONS=${1:-3}  # Number of runs per test (default: 3)

if [ ! -x "$COMPILER" ]; then
    echo "Building compiler..."
    (cd "$PROJECT_DIR" && dub build)
fi

echo -e "${CYAN}${BOLD}CTFE Backend Benchmark${NC}"
echo -e "Backends: ${BACKENDS[*]}"
echo -e "Iterations per test: $ITERATIONS"
echo

# Collect benchmark test files
test_files=()
if [ -d "$TESTS_DIR" ]; then
    for f in "$TESTS_DIR"/*.d; do
        [ -f "$f" ] && test_files+=("$f")
    done
fi

# Also include parity tests
PARITY_DIR="$PROJECT_DIR/tests/ctfe_parity"
for test_dir in $(find "$PARITY_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort); do
    [ -f "$test_dir/test.d" ] && test_files+=("$test_dir/test.d")
done

if [ ${#test_files[@]} -eq 0 ]; then
    echo -e "${RED}No test files found${NC}"
    exit 1
fi

echo -e "${CYAN}Found ${#test_files[@]} test files${NC}"
echo

# Extract a value after a key= prefix from a timing line (macOS-compatible)
extract_field() {
    local line="$1"
    local key="$2"
    echo "$line" | sed -n "s/.*${key}=\([^,]*\).*/\1/p"
}

# Run a single test and extract timing from -vv output
run_benchmark() {
    local test_file="$1"
    local backend="$2"

    local start_ns end_ns output
    start_ns=$(python3 -c "import time; print(int(time.time_ns()))")
    output=$("$COMPILER" --backend="$backend" -vv "$test_file" -o /dev/null 2>&1) || true
    end_ns=$(python3 -c "import time; print(int(time.time_ns()))")

    local wall_us=$(( (end_ns - start_ns) / 1000 ))

    # Extract CTFE timing line from -vv output
    local timing_line
    timing_line=$(echo "$output" | grep "Timing:" || echo "")

    echo "$wall_us|$timing_line"
}

# Format microseconds for display
fmt_us() {
    local us=$1
    if [ "$us" -lt 1000 ]; then
        echo "${us} us"
    elif [ "$us" -lt 1000000 ]; then
        python3 -c "print(f'{$us/1000:.1f} ms')"
    else
        python3 -c "print(f'{$us/1000000:.2f} s')"
    fi
}

# Print header
printf "${BOLD}%-22s  %-14s %-14s  %-14s %-14s${NC}\n" "Test" "wasm (wall)" "wasm (ctfe)" "native (wall)" "native (ctfe)"
printf "%-22s  %-14s %-14s  %-14s %-14s\n" "$(printf '%0.s─' {1..22})" "$(printf '%0.s─' {1..14})" "$(printf '%0.s─' {1..14})" "$(printf '%0.s─' {1..14})" "$(printf '%0.s─' {1..14})"

for test_file in "${test_files[@]}"; do
    test_name="$(basename "$(dirname "$test_file")")"
    [ "$test_name" = "tests" ] && test_name="$(basename "$test_file" .d)"

    # Truncate long names
    if [ ${#test_name} -gt 21 ]; then
        test_name="${test_name:0:18}..."
    fi

    wasm_wall="" wasm_ctfe=""
    native_wall="" native_ctfe=""

    for backend in "${BACKENDS[@]}"; do
        best_wall=999999999
        best_timing=""

        for ((i=1; i<=ITERATIONS; i++)); do
            result=$(run_benchmark "$test_file" "$backend")
            wall=$(echo "$result" | cut -d'|' -f1)
            timing=$(echo "$result" | cut -d'|' -f2-)

            if [ "$wall" -lt "$best_wall" ]; then
                best_wall=$wall
                best_timing="$timing"
            fi
        done

        wall_fmt=$(fmt_us "$best_wall")

        if [ -n "$best_timing" ]; then
            ctfe_total=$(extract_field "$best_timing" "total")
            ctfe_fmt="${ctfe_total:-n/a}"
        else
            ctfe_fmt="no CTFE"
        fi

        if [ "$backend" = "wasm" ]; then
            wasm_wall="$wall_fmt"
            wasm_ctfe="$ctfe_fmt"
        else
            native_wall="$wall_fmt"
            native_ctfe="$ctfe_fmt"
        fi
    done

    printf "%-22s  %-14s %-14s  %-14s %-14s\n" "$test_name" "$wasm_wall" "$wasm_ctfe" "$native_wall" "$native_ctfe"
done

echo
echo -e "${CYAN}Best of $ITERATIONS runs. CTFE time = analysis+compile+exec (from -vv).${NC}"
