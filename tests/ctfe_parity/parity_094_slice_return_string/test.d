string[] make_strings() {
    string[] arr;
    arr ~= "hello";
    arr ~= "world";
    arr ~= "test";
    return arr;
}

int test() {
    string[] arr = make_strings();
    // Verify by checking lengths: 5 + 5 + 4 = 14
    return arr[0].length + arr[1].length + arr[2].length;
}

enum RESULT = test();
int main() { return RESULT; }
