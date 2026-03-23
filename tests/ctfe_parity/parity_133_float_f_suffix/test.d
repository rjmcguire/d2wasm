// Float literal f suffix: 2.0f should be parsed as Float32
int compute() {
    float a = 2.0f;
    float b = 3.0f;
    return cast(int)(a + b);
}

enum RESULT = compute();
int main() { return RESULT; }
