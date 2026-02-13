struct Pair(T, U) {
    T first;
    U second;
}

alias IntPair = Pair!(int, int);

int sum(IntPair p) {
    return p.first + p.second;
}

enum RESULT = sum(IntPair(17, 25));

int main() {
    return RESULT;  // 42
}
