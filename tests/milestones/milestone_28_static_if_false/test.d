static if (false) {
    enum x = 1;
} else {
    enum x = 2;
}

int result() {
    return x;
}
