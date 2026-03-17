// EXPECTED: 32767
// EXPECTED: -32768
int main() {
    short maxS = 32767;
    short minS = -32768;
    __writeln(maxS);
    __writeln(minS);
    return 0;
}
