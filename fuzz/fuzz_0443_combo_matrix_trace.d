// EXPECTED: 15
int main() {
    int[3][3] m = [[1,2,3],[4,5,6],[7,8,9]];
    int trace = 0;
    for (int i = 0; i < 3; i++) trace += m[i][i];
    __writeln(trace);
    return 0;
}
