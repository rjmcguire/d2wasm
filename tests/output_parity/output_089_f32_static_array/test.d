// Output Parity Test: float (f32) static array
// Verifies float[N] init, element access, and function passing

void fillArray(float[4]* arr) {
    (*arr)[0] = 1.0;
    (*arr)[1] = 2.0;
    (*arr)[2] = 3.0;
    (*arr)[3] = 4.0;
}

float sumArray(float[4]* arr) {
    float s = 0.0;
    for (int i = 0; i < 4; i++) {
        s = s + (*arr)[i];
    }
    return s;
}

int main() {
    float[4] arr = [1.5, 2.5, 3.5, 4.5];

    // Verify init
    if (arr[0] != 1.5) return 1;
    if (arr[1] != 2.5) return 2;
    if (arr[2] != 3.5) return 3;
    if (arr[3] != 4.5) return 4;

    // Overwrite via pointer
    fillArray(&arr);
    if (arr[0] != 1.0) return 5;
    if (arr[3] != 4.0) return 6;

    // Sum via function: 1+2+3+4 = 10.0
    float s = sumArray(&arr);
    if (s != 10.0) return 7;

    // Verify element-level writes don't corrupt neighbors (4-byte elements)
    arr[1] = 99.0;
    if (arr[0] != 1.0) return 8;
    if (arr[2] != 3.0) return 9;

    return 42;
}
