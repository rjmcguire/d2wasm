int main() {
    int[] a;
    a ~= 10;
    a ~= 20;
    a ~= 30;
    return a[0] + a[1] + a[2];  // 60
}
