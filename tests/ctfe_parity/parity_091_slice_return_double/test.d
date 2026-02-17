double[] make_doubles() {
    double[] arr;
    arr ~= 1.5;
    arr ~= 2.5;
    arr ~= 3.5;
    return arr;
}

int test() {
    double[] arr = make_doubles();
    // Sum = 7.5, cast to int = 7
    return cast(int)(arr[0] + arr[1] + arr[2]);
}

enum RESULT = test();
int main() { return RESULT; }
