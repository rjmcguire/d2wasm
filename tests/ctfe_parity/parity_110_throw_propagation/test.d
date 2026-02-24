// CTFE Parity Test: throw propagation across function calls
// throw in callee, catch in caller

int thrower() {
    throw 99;
    return 0;
}

int caller() {
    try {
        return thrower();
    } catch (int e) {
        return e;
    }
}

enum RESULT = caller();

int main() {
    return RESULT;
}
