// EXPECTED: 1
// EXPECTED: 2
// EXPECTED: 3
struct Triple {
    int[3] vals;
}

int main() {
    Triple t;
    t.vals = [1, 2, 3];
    __writeln(t.vals[0]);
    __writeln(t.vals[1]);
    __writeln(t.vals[2]);
    return 0;
}
