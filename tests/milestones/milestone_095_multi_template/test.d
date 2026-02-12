// Test multiple instantiations of the same template with different types.
// Both int and uint map to i32 in WASM but are distinct D types,
// so this verifies re-parse isolation without requiring i64 support.

T max(T)(T a, T b) {
    if (a > b) return a;
    return b;
}

T identity(T)(T x) {
    return x;
}

int main() {
    int a = max!int(3, 8);
    uint b = max!uint(cast(uint)30, cast(uint)42);
    int c = identity!int(a);
    return c + cast(int)b;
}
