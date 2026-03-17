int[] makeData() {
    auto a = [1, 2, 3];
    return a;
}

int main() {
    __arena_new();
    int[] data = makeData();
    __arena_drop();
    int x = data[0];
    return x;
}
