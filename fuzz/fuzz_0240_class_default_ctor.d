// STATUS: wontfix — new requires @gc annotation
// EXPECTED: 0
class Simple {
    int x;
    int getX() { return x; }
}

int main() {
    auto s = new Simple();
    __writeln(s.getX());
    return 0;
}
