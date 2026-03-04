int main() {
    int i = 7;
    double d = cast(double) i;         // 7.0
    double d2 = cast(double)(i + 3);   // 10.0
    int back = cast(int)(d * d2);      // 70
    double neg = cast(double)(-5);     // -5.0
    int neg_back = cast(int) neg;      // -5
    return back + neg_back;            // 65
}
