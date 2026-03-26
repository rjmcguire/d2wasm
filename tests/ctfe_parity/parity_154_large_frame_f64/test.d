// Bug: emitLoadLocalF64ToD1 (and other ARM64 offset-taking instructions)
// did not handle offsets exceeding the 12-bit immediate field.  With a large
// struct on the stack, f64 locals at high offsets produce corrupted opcodes
// → EXC_BAD_INSTRUCTION at runtime.

struct BigBuffer {
    int[4096] data;   // 16 KB — pushes subsequent locals past imm12 threshold
    int len;
}

int main() {
    BigBuffer buf;
    buf.len = 0;

    // f64 variables at high stack offsets exercise emitLoadLocalF64ToD1
    // and emitStoreLocalF64 / emitLoadLocalF64 large-offset paths
    double a = 3.0;
    double b = 4.0;
    double c = a + b;
    if (c > 7.5) return 1;
    if (c < 6.5) return 2;

    // Division exercises the d1 load (binary right operand)
    double d = c / 2.0;
    if (d > 4.0) return 3;
    if (d < 3.0) return 4;

    return 42;
}
