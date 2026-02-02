string makeCode() {
    return "int x = 42;";
}

enum code = makeCode();
mixin(code);

int result() {
    return x;
}
