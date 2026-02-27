import mathlib;

// CTFE in root module — calls function defined in imported module.
// The root module's CTFE evaluator must compile mathlib.triangle().
enum TRI_10 = triangle(10);  // 1+2+...+10 = 55

int main() {
    return TRI_10;
}
