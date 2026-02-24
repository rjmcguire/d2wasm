// CTFE Parity Test: basic try-catch
// throw an int, catch it, return the caught value

int tryCatch() {
    try {
        throw 42;
    } catch (int e) {
        return e;
    }
    return 0;
}

enum RESULT = tryCatch();

int main() {
    return RESULT;
}
