// CTFE builtin to output during compile time
void ctfeMain() {
    __writeln("hello world");
}

// Trigger CTFE
enum _ = ctfeMain();
