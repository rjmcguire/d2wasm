// Bitwise OR and XOR on long values
int compute() {
    long a = 0xFF00000000;
    long b = 0x00FF000000;
    long ored = a | b;       // 0xFFFF000000
    long xored = ored ^ a;   // 0x00FF000000 = b
    return cast(int)(xored >> 24);  // 0xFF = 255
}

enum RESULT = compute();
int main() { return RESULT; }
