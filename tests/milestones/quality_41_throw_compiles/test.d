int foo() {
    try {
        throw 42;
    } catch (int e) {
        return e;
    }
    return 0;
}

int main() {
    return foo();
}
