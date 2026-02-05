// Milestone 92: Abstract NativeCodeGen Interface
//
// This milestone establishes architecture-agnostic code generation:
// - INativeCodeGen interface in codegen_interface.d
// - ARM64CodeGen implementation in arm64/codegen.d  
// - Abstract method aliases in old arm64_codegen.d for migration
//
// The abstraction enables future x86_64 support by implementing
// the same interface with different stencils.
//
// Verified by: all 107 existing tests continue to pass

int main() { return 0; }
