// EXPECTED: 0
// EXPECTED: 1
// EXPECTED: 2
// EXPECTED: 3
// EXPECTED: 4
// EXPECTED: 5
int main() {
    int[3][2] mat = [[0, 1, 2], [3, 4, 5]];
    for (int i = 0; i < 2; i++) {
        for (int j = 0; j < 3; j++) {
            __writeln(mat[i][j]);
        }
    }
    return 0;
}
