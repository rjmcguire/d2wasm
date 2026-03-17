// EXPECTED: a
// EXPECTED: b
// EXPECTED: c
void printA() { __writeln("a"); }
void printB() { __writeln("b"); }
void printC() { __writeln("c"); }

int main() {
    printA();
    printB();
    printC();
    return 0;
}
