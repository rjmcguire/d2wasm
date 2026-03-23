// STATUS: maybeLater — do-while not parsed
// EXPECTED: 15
int main() {
    int sum = 0;
    int i = 1;
    do {
        sum += i;
        i++;
    } while (i <= 5);
    __writeln(sum);
    return 0;
}
