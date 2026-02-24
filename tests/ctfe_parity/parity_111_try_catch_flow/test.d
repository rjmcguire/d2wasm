// CTFE Parity Test: try body runs normally, catch is NOT entered
// Verifies that catch is skipped when no exception is thrown

int normalFlow() {
    int result = 0;
    try {
        result = 10;
    } catch (int e) {
        result = -1;
    }
    return result;
}

enum RESULT = normalFlow();

int main() {
    return RESULT;
}
