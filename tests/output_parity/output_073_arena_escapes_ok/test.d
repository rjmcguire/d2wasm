void inc(ref int x) {
    x = x + 1;
}

int main() {
    int a = 41;
    inc(a);
    return a;
}
