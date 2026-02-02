enum code = "int x = undefined_var;";
mixin(code);

int result() {
    return x;
}
