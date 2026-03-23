// STATUS: wontfix — new requires @gc annotation
// EXPECTED: 10
// EXPECTED: 20
interface Sizable {
    int size();
}

class SmallThing : Sizable {
    int size() { return 10; }
}

class BigThing : Sizable {
    int size() { return 20; }
}

int main() {
    auto s = new SmallThing();
    auto b = new BigThing();
    __writeln(s.size());
    __writeln(b.size());
    return 0;
}
