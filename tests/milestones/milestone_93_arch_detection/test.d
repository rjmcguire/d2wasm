// Milestone 93: Architecture Auto-Detection
//
// --backend=native now auto-detects the host architecture:
// - ARM64 (aarch64): Uses NativeBackend with ARM64 stencils
// - x86_64 (amd64): Clear error message (not yet implemented)
// - Other: Clear error suggesting --backend=wasm
//
// Also supports explicit --backend=native-arm64 for testing.

int main() { return 0; }
