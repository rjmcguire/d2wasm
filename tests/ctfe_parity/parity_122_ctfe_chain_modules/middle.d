module middle;

import base;

// CTFE in middle module — calls function from base module.
// middle's per-module evaluator compiles base.fib().
enum FIB_11 = fib(11);  // 89
