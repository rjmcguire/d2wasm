int main() {
    int[] arr = [1, 2, 3];
    arr ~= 42;
    return arr[3];  // Should be 42
}
