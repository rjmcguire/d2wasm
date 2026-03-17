// EXPECTED: 1
// EXPECTED: 0
int main() {
    bool t = true;
    bool f = false;
    __writeln(cast(int)t);
    __writeln(cast(int)f);
    return 0;
}
