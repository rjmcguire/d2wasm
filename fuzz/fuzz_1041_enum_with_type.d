// STATUS: maybeLater — named enum member access not implemented
// EXPECTED: 1
// EXPECTED: 2
// EXPECTED: 3
enum Tri : int { a = 1, b = 2, c = 3 }

int main() {
    __writeln(cast(int)Tri.a);
    __writeln(cast(int)Tri.b);
    __writeln(cast(int)Tri.c);
    return 0;
}
