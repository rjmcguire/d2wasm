int max(int a, int b) {
    if (a > b) {
        return a;
    } else {
        return b;
    }
}

enum RESULT = max(10, 25);  // 25

int main() { return RESULT; }
