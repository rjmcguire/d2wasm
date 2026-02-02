string makeCode() {
    mixin("string part = \"int x\";");
    return part ~ " = 42;";
}

enum code = makeCode();
mixin(code);

int result() {
    return x;
}
