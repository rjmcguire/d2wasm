// STATUS: maybeLater — literal narrowing not implemented
// EXPECTED: 255
// EXPECTED: 0
int main() {
    ubyte maxUB = 255;
    ubyte minUB = 0;
    __writeln(maxUB);
    __writeln(minUB);
    return 0;
}
