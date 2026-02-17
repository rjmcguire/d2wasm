bool[] make_bools() {
    bool[] arr;
    arr ~= true;
    arr ~= false;
    arr ~= true;
    return arr;
}

int test() {
    bool[] arr = make_bools();
    int sum = 0;
    if (arr[0]) sum = sum + 1;
    if (arr[1]) sum = sum + 10;
    if (arr[2]) sum = sum + 100;
    return sum;  // 101
}

enum RESULT = test();
int main() { return RESULT; }
