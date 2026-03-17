// EXPECTED: 1-a
int main() {
    int x = 1;
    int y = 0;
    switch (x) {
        case 0:
            switch (y) {
                case 0: __writeln("0-a"); break;
                default: __writeln("0-b"); break;
            }
            break;
        case 1:
            switch (y) {
                case 0: __writeln("1-a"); break;
                default: __writeln("1-b"); break;
            }
            break;
        default: break;
    }
    return 0;
}
