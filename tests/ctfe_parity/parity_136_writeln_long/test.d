// __writeln with long (i64) values
int compute() {
    long a = 1000000000;
    long b = 3;
    __writeln(a * b);
    return 0;
}

enum R = compute();
int main() { return R; }
