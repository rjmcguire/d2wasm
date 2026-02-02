enum val = 5;

static if (val > 3) {
    enum x = 10;
} else {
    enum x = 20;
}

int result() {
    return x;
}
