// Milestone 107: Incremental Compilation Command-Line Flags
//
// This milestone adds:
// - --cache=<dir>  Cache directory for incremental compilation
// - --staging=<file>  Staging file output path
// - --json  Output JSON summary
//
// When --cache is specified:
// - Creates/opens cache database
// - Records compiled functions
// - Writes staging file
//
// When --json is specified:
// - Outputs JSON with module, input, output, success, wasmSize, cache stats
//
// Test: compile with --json and verify output contains "success": true

int add(int a, int b) {
    return a + b;
}
