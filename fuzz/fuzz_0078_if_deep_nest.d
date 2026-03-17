// EXPECTED: deep
int main() {
    int a = 1;
    if (a > 0) {
        if (a < 10) {
            if (a == 1) {
                if (a != 0) {
                    __writeln("deep");
                }
            }
        }
    }
    return 0;
}
