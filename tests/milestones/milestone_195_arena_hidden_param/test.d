// Tests that hidden __arena parameter is threaded through function calls.
// build_sum: needs arena (direct ~= allocation), gets hidden arena param
// main: needs arena (transitive), passes arena to build_sum

int build_sum(int a, int b, int c) {
    int[] arr;
    arr ~= a;
    arr ~= b;
    arr ~= c;
    return arr[0] + arr[1] + arr[2];
}

int main() {
    return build_sum(10, 20, 12);  // 42
}
