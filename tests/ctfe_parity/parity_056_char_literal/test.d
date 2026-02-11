int test() {
    char c = 'A';   // 65
    char d = '0';   // 48
    return cast(int)c + cast(int)d;  // 113
}

enum RESULT = test();

int main() {
    return RESULT;
}
