// EXPECTED: 25
int square(int x) { return x * x; }
alias sq = square;

int main() {
    __writeln(sq(5));
    return 0;
}
