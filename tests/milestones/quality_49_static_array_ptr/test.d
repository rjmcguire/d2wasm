int sumViaPtr(int* p, int n) {
    int total = 0;
    int i = 0;
    while (i < n) {
        total = total + p[i];
        i = i + 1;
    }
    return total;
}

int main() {
    int[5] arr;
    arr[0] = 1;
    arr[1] = 2;
    arr[2] = 3;
    arr[3] = 4;
    arr[4] = 5;

    // .ptr gives address of the first element
    int* p = arr.ptr;

    // Pass pointer to function
    int sum = sumViaPtr(p, 5);  // 1+2+3+4+5 = 15

    return sum;
}
