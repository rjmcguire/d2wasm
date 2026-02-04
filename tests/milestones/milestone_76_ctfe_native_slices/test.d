// Milestone 76: CTFE slices in native backend
// Tests array literals and indexing via CTFE

int getSecond() {
    int[] arr = [10, 20, 30];
    return arr[1];
}

int sumArray() {
    int[] vals = [1, 2, 3, 4, 5];
    int sum = 0;
    int i = 0;
    while (i < 5) {
        sum = sum + vals[i];
        i = i + 1;
    }
    return sum;
}

// Force CTFE evaluation - both functions must work
enum second = getSecond();
enum total = sumArray();

int main() {
    // second=20, total=15 → 20+15=35
    return second + total;
}
