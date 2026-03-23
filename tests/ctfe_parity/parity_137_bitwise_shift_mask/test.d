// Bitwise shift and mask operations on hex literals
int compute() {
    int val = 0xABCD;
    int high_byte = (val >> 8) & 0xFF;  // 0xAB = 171
    return high_byte;
}

enum RESULT = compute();
int main() { return RESULT; }
