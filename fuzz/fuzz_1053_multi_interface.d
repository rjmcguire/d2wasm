// EXPECTED: 10
// EXPECTED: name
interface Sized {
    int size();
}

interface Named {
    string name();
}

class Thing : Sized, Named {
    int size() { return 10; }
    string name() { return "name"; }
}

int main() {
    auto t = new Thing();
    __writeln(t.size());
    __writeln(t.name());
    return 0;
}
