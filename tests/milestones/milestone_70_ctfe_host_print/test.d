// Milestone 70: CTFE host function - __ctfe_print_i32
// Tests that CTFE can call a host function via WASM imports

int printAndReturn(int x) {
    __ctfe_print_i32(x);
    return x + 1;
}

// Force CTFE evaluation
enum result = printAndReturn(42);

int main() {
    // Return the CTFE-computed result
    return result;
}
