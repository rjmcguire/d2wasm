int inc(int x) { return x + 1; }
int dbl(int x) { return x * 2; }

int test() {
    return inc(dbl(inc(dbl(5))));  // dbl(5)=10, inc(10)=11, dbl(11)=22, inc(22)=23
}

enum RESULT = test();
int main() { return RESULT; }
