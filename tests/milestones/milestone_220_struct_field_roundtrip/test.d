// Milestone 220: Struct field round-trip across function calls
//
// Verifies that struct fields written before a function call
// survive and can be read back after the call returns.
// This tests that shadow stack frame layout properly accounts
// for struct sizes and that intervening calls don't clobber data.

struct Rect {
    double x;
    double y;
    double w;
    double h;
}

int identity(int x) {
    return x;
}

int main() {
    Rect r;
    r.x = 10.0;
    r.y = 20.0;
    r.w = 30.0;
    r.h = 40.0;

    // Intervening function call — must not clobber struct fields
    int dummy = identity(42);

    // Read back all four fields
    double sum = r.x + r.y + r.w + r.h;

    // 10 + 20 + 30 + 40 = 100
    return cast(int)sum;
}
