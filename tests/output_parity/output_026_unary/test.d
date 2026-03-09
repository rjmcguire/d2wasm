int test() {
    int a = 42;
    int b = -a;      // -42
    int c = ~0;      // -1
    return -(b + c); // -(-43) = 43
}

int main() { return test(); }
