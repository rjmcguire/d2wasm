int[] makeData() {
    auto a = [3, 2, 1];
    return a;
}

int main() {
    int[] data = makeData();
    return data[0] + data[1] + data[2];
}
