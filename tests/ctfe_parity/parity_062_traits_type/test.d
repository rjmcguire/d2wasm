// Test __traits type property checks inside CTFE function body

int test() {
    int result = 0;
    if (__traits(isArithmetic, int)) result += 1;
    if (__traits(isIntegral, int)) result += 2;
    if (!__traits(isFloating, int)) result += 4;
    if (!__traits(isUnsigned, int)) result += 8;
    if (__traits(isSigned, int)) result += 16;
    return result;
}

enum RESULT = test();

int main() {
    return RESULT;
}
