enum code = "int x = 42;";
mixin(code);

int result() {
    return x;
}
