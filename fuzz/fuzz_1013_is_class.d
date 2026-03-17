// EXPECTED: 1
// EXPECTED: 0
class Foo {}

int main() {
    static if (is(Foo == class)) __writeln(1);
    else __writeln(0);
    static if (is(int == class)) __writeln(1);
    else __writeln(0);
    return 0;
}
