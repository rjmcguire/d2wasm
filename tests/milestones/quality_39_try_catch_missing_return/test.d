int foo() {
    try {
        throw 1;
        return 0;
    } catch (int e) {
        int x = e + 1;
    }
}
