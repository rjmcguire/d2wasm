// Multi-step string concatenation
// Tests that WASM codegen handles chained concats
enum A = "Hello";
enum B = " ";
enum C = "World";
enum D = A ~ B ~ C;  // Chained: (A ~ B) ~ C

void printIt() {
    __writeln(D);
}
enum _ = printIt();
