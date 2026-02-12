// Test checked shift operator traps on out-of-range amount

enum X = opShiftLeft(1, 64);

int result() {
    return X;
}
