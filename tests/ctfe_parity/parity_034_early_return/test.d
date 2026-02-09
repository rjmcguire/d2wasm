int findFirst(int target) {
    int i = 0;
    while (i < 100) {
        if (i == target) {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

int test() {
    return findFirst(42);
}

enum RESULT = test();
int main() { return RESULT; }
