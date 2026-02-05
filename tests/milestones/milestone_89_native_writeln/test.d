// Milestone 89: Native __writeln support
// __writeln is lowered to __ctfe_write_i32 + __ctfe_write_newline

int printValue(int x) {
    __writeln(x);
    return x + 1;
}

// Force CTFE evaluation
enum result = printValue(42);

int main() {
    return result;
}
