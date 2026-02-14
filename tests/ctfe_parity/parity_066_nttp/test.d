int addN(int N)(int x) {
    return x + N;
}

struct Sized(int N) {
    int length() {
        return N;
    }
}

int test() {
    int a = addN!(10)(5);       // 15
    int b = addN!(20)(7);       // 27
    Sized!(3) s;
    int c = s.length();         // 3
    return a + b + c;           // 45
}

enum RESULT = test();
int main() { return RESULT; }
