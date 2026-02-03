int main() {
    int[] arr = [1, 2, 3];
    arr.length = 5;
    return arr.length + arr[4];  // 5 + 0 = 5 (new elements zero-initialized)
}
