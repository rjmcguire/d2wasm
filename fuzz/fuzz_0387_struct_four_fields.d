// EXPECTED: 10
struct Q { int a; int b; int c; int d; }

int main() {
    auto q = Q(1, 2, 3, 4);
    __writeln(q.a + q.b + q.c + q.d);
    return 0;
}
