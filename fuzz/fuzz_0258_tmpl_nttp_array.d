// STATUS: maybeLater — type not implemented
// EXPECTED: 3
// EXPECTED: 5
struct Sized(int N) {
    int[N] data;

    int size() { return N; }
}

int main() {
    auto a = Sized!3();
    auto b = Sized!5();
    __writeln(a.size());
    __writeln(b.size());
    return 0;
}
