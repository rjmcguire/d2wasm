import middle;

// middle.FIB_11 was evaluated by middle's CTFE evaluator,
// which compiled base.fib() as a cross-module dependency.
int main() {
    return FIB_11;  // fib(11) = 89
}
