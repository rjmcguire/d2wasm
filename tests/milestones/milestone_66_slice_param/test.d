// Milestone 66: Slice as function parameter
// Pass a slice to a function, read elements inside

int sumFirst3(int[] arr) {
    return arr[0] + arr[1] + arr[2];
}

int main() {
    int[] data = [10, 20, 30, 40];
    return sumFirst3(data);
}
