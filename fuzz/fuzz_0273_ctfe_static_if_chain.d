// EXPECTED: medium
enum val = 50;

int main() {
    static if (val < 10) {
        __writeln("small");
    } else static if (val < 100) {
        __writeln("medium");
    } else {
        __writeln("large");
    }
    return 0;
}
