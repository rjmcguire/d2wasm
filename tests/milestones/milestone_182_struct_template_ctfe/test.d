// Test struct template in CTFE

struct Pair(T, U) {
    T first;
    U second;
}

int computeSum() {
    Pair!(int, int) p = Pair!(int, int)(100, 200);
    return p.first + p.second;
}

enum result = computeSum();

int main() {
    return result;
}
