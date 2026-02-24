int main() {
    int y = 10;
    auto dg = (int x) => x + y;
    y = 20;
    return dg(5);
}
