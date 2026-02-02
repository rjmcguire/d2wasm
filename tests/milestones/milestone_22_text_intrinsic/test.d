enum n = 42;
enum msg = "value: " ~ __text(n);

void main() {
    __writeln(msg);
}

enum _ = main();
