// EXPECTED: 10
// EXPECTED: 20
// EXPECTED: 30
enum Val { a = 10, b = 20, c = 30 }

int main() {
    __writeln(cast(int)Val.a);
    __writeln(cast(int)Val.b);
    __writeln(cast(int)Val.c);
    return 0;
}
