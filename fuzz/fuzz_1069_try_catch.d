// EXPECTED: caught
int main() {
    try {
        throw new Exception("oops");
    } catch (Exception e) {
        __writeln("caught");
    }
    return 0;
}
