// Milestone 72: __writeln with string and mixed arguments
// Tests that __writeln("str", value) lowers correctly to WASM

int printAndCompute(int x) {
    __writeln("Value: ", x);
    return x + 1;
}

// Force CTFE evaluation
enum result = printAndCompute(42);

int main() {
    return result;
}
