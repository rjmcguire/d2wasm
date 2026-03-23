// Integer L suffix forces Int64 type
int compute() {
    long x = 42L;
    return cast(int)x;
}

enum RESULT = compute();
int main() { return RESULT; }
