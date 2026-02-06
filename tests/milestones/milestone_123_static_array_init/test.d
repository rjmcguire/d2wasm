// Milestone 123: Static array literal initialization
// Tests:
// - Initializing static array with array literal
// - Type compatibility: int[] → int[4]

int main() {
    int[4] arr = [1, 2, 3, 4];
    return arr[1] + arr[3];  // 2 + 4 = 6
}
