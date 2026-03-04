int main() {
    double x = 7.5;
    double neg = -x;          // -7.5
    double pos = +x;          // 7.5
    double neglit = -3.25;    // -3.25 (literal negation)
    double double_neg = -(-x); // 7.5
    return cast(int)(neg + pos + neglit + double_neg); // 4
}
