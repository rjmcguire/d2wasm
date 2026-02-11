int test() {
    string s = "Hello";
    return s[0] + s[4];   // 'H'(72) + 'o'(111) = 183
}

enum RESULT = test();

int main() {
    return RESULT;
}
