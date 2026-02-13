// Test multiple instantiations of the same struct template

struct Pair(T, U) {
    T first;
    U second;
}

int main() {
    Pair!(int, int) a = Pair!(int, int)(10, 20);
    Pair!(int, int) b = Pair!(int, int)(3, 4);
    return a.first + a.second + b.first + b.second;
}
