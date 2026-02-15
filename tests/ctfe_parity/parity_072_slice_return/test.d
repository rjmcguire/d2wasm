int first(int[] data) {
    return data[0];
}

int[] tail(int[] data) {
    return data[1..data.length];
}

int test() {
    int[] arr = [10, 20, 30, 40];
    int[] t = tail(arr);
    return first(t) + t[1] + t[2];  // 20+30+40=90
}

enum RESULT = test();
int main() { return RESULT; }
