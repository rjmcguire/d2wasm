int test() {
    int[] data = [10, 20, 30, 40, 50];
    int start = 1;
    int end = 4;
    int[] sub = data[start..end];
    return sub[0] + sub[1] + sub[2];
}

enum RESULT = test();
int main() { return RESULT; }
