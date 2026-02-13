// Tests that arena analysis correctly identifies allocating functions
// pure_math: no arena needed (pure computation)
// make_array: needs arena (direct ~= allocation)
// use_array: needs arena (transitive, calls make_array)
// main: needs arena (transitive, calls use_array)

int pure_math(int x) {
    return x * 2;
}

int[] make_array(int val) {
    int[] a;
    a ~= val;
    return a;
}

int use_array() {
    auto arr = make_array(21);
    return arr[0];
}

int main() {
    return pure_math(use_array());  // pure_math(21) = 42
}
