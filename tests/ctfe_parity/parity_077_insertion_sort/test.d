int test() {
    int[7] arr;
    arr[0] = 38; arr[1] = 27; arr[2] = 43;
    arr[3] = 3;  arr[4] = 9;  arr[5] = 82;
    arr[6] = 10;

    // Insertion sort
    int i = 1;
    while (i < 7) {
        int key = arr[i];
        int j = i - 1;
        while (j >= 0 && arr[j] > key) {
            arr[j + 1] = arr[j];
            j = j - 1;
        }
        arr[j + 1] = key;
        i = i + 1;
    }

    // Sorted: [3, 9, 10, 27, 38, 43, 82]
    // Median (middle element) = arr[3] = 27
    return arr[3];
}

enum RESULT = test();
int main() { return RESULT; }
