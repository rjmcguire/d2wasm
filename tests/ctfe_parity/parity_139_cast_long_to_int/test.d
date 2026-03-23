// Cast long expression to int via i32.wrap_i64
int compute() {
    long x = 5000000000;
    return cast(int)(x % 100);
}

enum RESULT = compute();
int main() { return RESULT; }
