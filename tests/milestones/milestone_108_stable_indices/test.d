// Test for stable index assignment across compilations
// Multiple functions with different signatures to exercise type sorting

int add(int a, int b) {
    return a + b;
}

int sub(int a, int b) {
    return a - b;
}

int identity(int x) {
    return x;
}

int main() {
    int x = add(10, 5);      // 15
    int y = sub(10, 3);      // 7
    int z = identity(8);     // 8
    return x + y + z;        // 30
}
