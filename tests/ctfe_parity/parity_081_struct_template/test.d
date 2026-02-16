struct Pair(T, U) {
    T first;
    U second;
}

int test() {
    Pair!(int, int) p = Pair!(int, int)(100, 200);
    return p.first + p.second;
}

enum RESULT = test();
int main() { return RESULT; }
