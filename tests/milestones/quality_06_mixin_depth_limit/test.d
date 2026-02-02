// This creates infinite mixin expansion
enum code = "mixin(code);";
mixin(code);

int result() {
    return 42;
}
