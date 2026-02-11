int sum(int[] s) {
    int total = 0;
    int i = 0;
    while (i < s.length) {
        total = total + s[i];
        i = i + 1;
    }
    return total;
}

int test() {
    int[] data = [10, 20, 30, 40, 50];
    return sum(data[1..4]);
}

enum RESULT = test();

int main() {
    return RESULT;
}
