// Milestone 124: CTFE with static arrays
// Tests:
// - Static array creation and manipulation in CTFE
// - Returning static arrays from CTFE functions (via hidden __result parameter)
// - Using CTFE array results as manifest constants

int[4] makeTable() {
    int[4] t;
    t[0] = 10;
    t[1] = 20;
    t[2] = 30;
    t[3] = 40;
    return t;
}

enum table = makeTable();

int main() {
    return table[1];  // 20
}
