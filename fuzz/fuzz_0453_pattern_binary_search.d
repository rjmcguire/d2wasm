// EXPECTED: 4
int bsearch(int[8] arr, int target) {
    int lo = 0;
    int hi = 7;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        if (arr[mid] == target) return mid;
        if (arr[mid] < target) lo = mid + 1;
        else hi = mid - 1;
    }
    return -1;
}

int main() {
    int[8] a = [2, 4, 6, 8, 10, 12, 14, 16];
    __writeln(bsearch(a, 10));
    return 0;
}
