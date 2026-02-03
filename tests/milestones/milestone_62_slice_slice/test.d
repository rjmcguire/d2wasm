int main() {
    int[] arr = [10, 20, 30, 40, 50];
    int[] sub = arr[1..4];
    return sub[0] + sub.length;  // 20 + 3 = 23
}
