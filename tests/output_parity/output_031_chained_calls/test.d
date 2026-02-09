int inc(int x) { return x + 1; }
int dbl(int x) { return x * 2; }

int main() {
    return inc(dbl(inc(dbl(5))));
}
