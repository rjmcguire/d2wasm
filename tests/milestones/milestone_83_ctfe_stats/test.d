// Milestone 83: CTFE stats tracking
// Verify stats work without errors

int helper() { return 5; }
int compute(int x) { return x + helper(); }

enum a = compute(10);  // 15
enum b = compute(20);  // 25

int main() {
    return a + b;  // 40
}
