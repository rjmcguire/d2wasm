enum MSG = "hello from manifest constant";

void greet() {
    __writeln(MSG);
}
enum _ = greet();
