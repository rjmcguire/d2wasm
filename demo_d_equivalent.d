// This D program demonstrates the target for WASI console output
// The generated WASM should behave identically to this when run with wasmtime

int main() {
    writeln("Hello from WASI D!");
    writeln("The answer is: ");
    writeln(42);
    writeln("Pi approximation: ");
    writeln(3.14159);
    writeln();
    writeln("Program completed successfully!");
    return 0;
}