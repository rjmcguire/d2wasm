int add5(int a, int b, int c, int d, int e) {
    return a + b + c + d + e;
}

int add8(int a, int b, int c, int d, int e, int f, int g, int h) {
    return a + b + c + d + e + f + g + h;
}

int main() {
    int x = add5(1, 2, 3, 4, 5);
    int y = add8(1, 2, 3, 4, 5, 6, 7, 8);
    return x + y;
}
