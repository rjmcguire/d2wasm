int result() {
    mixin("int x = 42;");
    return x;
}
