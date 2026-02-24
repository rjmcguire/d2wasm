int thrower() {
    throw 42;
    return 0;
}

int middle() {
    return thrower();
}

enum RESULT = middle();
