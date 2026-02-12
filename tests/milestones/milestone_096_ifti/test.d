// Test IFTI: Implicit Function Template Instantiation
// max(3, 8) should deduce T=int without explicit !int

T max(T)(T a, T b) {
    if (a > b) return a;
    return b;
}

int main() {
    return max(3, 8);
}
