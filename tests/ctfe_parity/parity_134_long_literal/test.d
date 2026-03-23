// Large integer literal auto-promoted to Int64
int compute() {
    long x = 5000000000;
    return cast(int)(x - 4999999990);
}

enum RESULT = compute();
int main() { return RESULT; }
