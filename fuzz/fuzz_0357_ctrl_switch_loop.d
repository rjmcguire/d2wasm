// EXPECTED: 3
int main() {
    int sum = 0;
    for (int i = 0; i < 5; i++) {
        switch (i) {
            case 1: sum += 1; break;
            case 3: sum += 2; break;
            default: break;
        }
    }
    __writeln(sum);
    return 0;
}
