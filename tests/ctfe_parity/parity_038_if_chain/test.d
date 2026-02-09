int classify(int x) {
    if (x < 0) {
        return -1;
    } else if (x == 0) {
        return 0;
    } else if (x < 10) {
        return 1;
    } else {
        return 2;
    }
}

int test() {
    return classify(-5) + classify(0) + classify(5) + classify(100);
    // -1 + 0 + 1 + 2 = 2
}

enum RESULT = test();
int main() { return RESULT; }
