// STATUS: maybeLater — final_switch_statement not implemented
// EXPECTED: b
enum E { a, b, c }

int main() {
    E val = E.b;
    final switch (val) {
        case E.a: __writeln("a"); break;
        case E.b: __writeln("b"); break;
        case E.c: __writeln("c"); break;
    }
    return 0;
}
