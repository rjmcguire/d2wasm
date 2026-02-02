static if (true) {
    int result() {
        return 42;
    }
} else {
    int result() {
        return "this would be a type error";
    }
}
