int test() {
    string a = "hello";
    string b = "hello";
    string c = "world";

    int result = 0;
    if (stringEqual(a, b)) result = result + 1;
    if (!stringEqual(a, c)) result = result + 10;
    return result;
}

enum RESULT = test();

int main() {
    return RESULT;
}
