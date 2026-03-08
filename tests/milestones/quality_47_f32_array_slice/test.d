int main() {
    float[3] arr;
    arr[0] = 1.5;
    arr[1] = 2.5;
    arr[2] = 3.5;

    // Index into float static array
    float sum = arr[0] + arr[1] + arr[2];  // 7.5

    // Slice of float array
    float[] sl = arr[0..2];
    float sl_sum = sl[0] + sl[1];  // 4.0

    return cast(int)(sum + sl_sum);  // 11
}
