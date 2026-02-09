int test() {
    int a = 42;
    int b = -a;
    int c = ~0;
    return b + c;
}

int main() { return test(); }
