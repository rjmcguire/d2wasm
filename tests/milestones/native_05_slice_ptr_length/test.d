int getLength(int[] arr) {
    return arr.length;
}

int main() {
    int[] arr = [10, 20, 30];
    if (arr.length != 3) return 1;
    if (getLength(arr) != 3) return 2;
    return 3;
}
