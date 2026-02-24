int thrower() {
    throw 42;
    return 0;
}

enum RESULT = thrower();
