// Milestone 88: Native backend host function calls
// Test that native CTFE can call __ctfe_print_i32

int printAndReturn() {
    __ctfe_print_i32(42);
    return 1;
}

// Force CTFE evaluation
enum result = printAndReturn();

int main() {
    return result;
}
