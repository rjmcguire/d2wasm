// Milestone 71: __writeln lowered to WASM imports
// Tests that __writeln(args...) is lowered to typed CTFE write calls

int printAndCompute(int x) {
    __writeln(x);
    return x + 1;
}

// Force CTFE evaluation
enum result = printAndCompute(42);

int main() {
    return result;
}
