int double_(int x) { return x * 2; }
int add(int a, int b) { return a + b; }

int main() {
    int a = double_(10);
    int b = double_(11);
    return add(a, b);
}
