// EXPECTED: 1
class Foo {}

int main() {
    Foo f = new Foo();
    if (f !is null) __writeln(1);
    else __writeln(0);
    return 0;
}
