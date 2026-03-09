int[3] makeArray(int a, int b, int c) {
    int[3] result = [a, b, c];
    return result;
}

int main() {
    int[3] arr = makeArray(10, 20, 30);
    return arr[0] + arr[1] + arr[2];  // 60
}
