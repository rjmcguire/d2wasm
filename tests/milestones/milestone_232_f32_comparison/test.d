int main() {
    float a = 3.14;
    float b = 2.72;
    int result = 0;
    if (a > b)  result = result + 1;   // true  -> 1
    if (a >= b) result = result + 2;   // true  -> 3
    if (b < a)  result = result + 4;   // true  -> 7
    if (b <= a) result = result + 8;   // true  -> 15
    if (a == a) result = result + 16;  // true  -> 31
    if (a != b) result = result + 32;  // true  -> 63
    if (a < b)  result = result + 64;  // false -> 63
    if (a == b) result = result + 128; // false -> 63
    return result;
}
