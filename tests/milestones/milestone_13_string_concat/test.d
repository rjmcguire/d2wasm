enum HELLO = "Hello" ~ " World";

void greet() {
    __writeln(HELLO);
}
enum _ = greet();
