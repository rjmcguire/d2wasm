int main() {
    double a = 1.1;
    double b = 2.2;
    double c = 3.3;
    double d = 4.4;
    double e = 5.5;
    double f = 6.6;
    double g = 7.7;
    double h = 8.8;
    // Use all of them to prevent optimization
    double sum = a + b + c + d + e + f + g + h; // 39.6
    // Modify middle vars and recheck
    d = -d;   // -4.4
    e = -e;   // -5.5
    // 1.1+2.2+3.3+(-4.4)+(-5.5)+6.6+7.7+8.8 = 19.8
    double sum2 = a + b + c + d + e + f + g + h;
    // 39.6 + 19.8 = 59.4 -> cast(int) = 59
    return cast(int)(sum + sum2);
}
