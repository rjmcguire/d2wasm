int test() {
    int[] arr;
    int i = 0;
    while (i < 4200) {
        arr ~= i;
        i = i + 1;
    }
    if (arr[0] != 0) return 1;
    if (arr[4199] != 4199) return 2;
    if (arr[2100] != 2100) return 3;
    return 0;
}

enum RESULT = test();
int main() { return RESULT; }
