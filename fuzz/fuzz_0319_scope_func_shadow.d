// EXPECTED: 5
// EXPECTED: 10
int x = 5;

void show() {
    __writeln(x);
}

int main() {
    show();
    int x = 10;
    __writeln(x);
    return 0;
}
