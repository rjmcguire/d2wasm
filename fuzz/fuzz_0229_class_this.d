// EXPECTED: 99
class Box {
    int value;

    this(int value) {
        this.value = value;
    }

    int getValue() {
        return this.value;
    }
}

int main() {
    auto b = new Box(99);
    __writeln(b.getValue());
    return 0;
}
