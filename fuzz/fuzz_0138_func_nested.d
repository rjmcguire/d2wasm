// EXPECTED: 25
int main() {
    int square(int x) {
        return x * x;
    }
    __writeln(square(5));
    return 0;
}
