// Milestone 110: Persistent code cache
//
// Tests that --cache enables incremental compilation:
// 1. First compilation: all functions compiled (cache misses)
// 2. Second compilation (same source): all cache hits
// 3. Modified source: only changed functions recompiled
//
// This is tested via a shell test (see config.json)

int add(int a, int b) {
    return a + b;
}

int main() {
    return add(1, 2);
}
