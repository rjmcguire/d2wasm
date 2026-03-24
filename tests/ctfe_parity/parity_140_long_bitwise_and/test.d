// Bitwise AND on long values
int compute() {
    long x = 0x00FF00FF00FF00FF;
    long mask = 0x0F0F0F0F0F0F0F0F;
    long result = x & mask;
    // 0x000F000F000F000F = 4222189076152335
    // lower 32 bits: 0x000F000F = 983055
    return cast(int)(result & 0xFFFF);  // lowest 16 bits = 0x000F = 15
}

enum RESULT = compute();
int main() { return RESULT; }
