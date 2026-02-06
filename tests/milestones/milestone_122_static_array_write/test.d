// Milestone 122: Static array index assignment
// Tests:
// - Writing to static array elements
// - Reading back written values

int main() {
    int[4] arr;
    arr[0] = 42;
    arr[1] = 10;
    arr[2] = arr[0] + arr[1];  // 52
    return arr[2];
}
