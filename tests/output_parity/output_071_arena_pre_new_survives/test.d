int[] makeData() {
    auto a = [42, 99];
    return a;
}

int main() {
    int[] outer = makeData();
    __arena_new();
    __arena_drop();
    return outer[0];
}
