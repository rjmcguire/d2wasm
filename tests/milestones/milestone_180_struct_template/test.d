// Test basic struct template instantiation

struct Pair(T, U) {
    T first;
    U second;
}

int main() {
    Pair!(int, int) p = Pair!(int, int)(10, 20);
    return p.first + p.second;
}
