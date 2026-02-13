// Tests that arena analysis runs correctly alongside allocating functions.
// pure_math: no arena needed (pure computation)
// build_sum: needs arena (direct ~= allocation)
// main: needs arena (transitive, calls build_sum)

int pure_math(int x) {
    return x * 2;
}

int build_sum() {
    int[] a;
    a ~= 10;
    a ~= 20;
    a ~= 30;
    return a[0] + a[1] + a[2];  // 60
}

int main() {
    return pure_math(build_sum()) - 78;  // 2*60 - 78 = 42
}
