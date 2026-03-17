// EXPECTED: 4
int sqrt_floor(int n)
in {
    assert(n >= 0);
}
out (result) {
    assert(result * result <= n);
}
do {
    int r = 0;
    while ((r + 1) * (r + 1) <= n) r++;
    return r;
}

int main() {
    __writeln(sqrt_floor(20));
    return 0;
}
