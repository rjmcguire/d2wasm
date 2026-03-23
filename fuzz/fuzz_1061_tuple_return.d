// STATUS: bug — wrong output
// EXPECTED: 3
// EXPECTED: 4
// Simulated tuple return via struct
struct Pair { int a; int b; }

Pair divmod(int a, int b) {
    return Pair(a / b, a % b);
}

int main() {
    auto r = divmod(10, 3);
    __writeln(r.a);
    __writeln(r.b);
    return 0;
}
