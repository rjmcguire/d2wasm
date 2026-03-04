int main() {
    double a = 10.5;
    double b = 3.25;
    double sum = a + b;       // 13.75
    double diff = a - b;      // 7.25
    double prod = a * b;      // 34.125
    double quot = a / b;      // 3.230769...
    return cast(int)(sum + diff + prod + quot); // 58
}
