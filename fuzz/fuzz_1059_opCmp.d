// EXPECTED: 1
struct Val {
    int x;

    int opCmp(Val other) {
        return x - other.x;
    }
}

int main() {
    auto a = Val(10);
    auto b = Val(5);
    if (a > b) __writeln(1); else __writeln(0);
    return 0;
}
