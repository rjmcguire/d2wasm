int[] makeData() {
    auto a = [1, 2, 3];
    return a;
}

int main() {
    __arena_new();
    int[] data = makeData();
    int x = data[0];
    __arena_drop();
    return x;
}
