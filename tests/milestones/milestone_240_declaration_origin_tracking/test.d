mixin("int mixedFunc() { return 42; }");

int normalFunc() {
    return mixedFunc();
}

int main() {
    return normalFunc();
}
