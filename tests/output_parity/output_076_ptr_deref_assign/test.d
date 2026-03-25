struct Val {
    int x;
}

void addTo(Val* v, int n) {
    v.x = v.x + n;
}

int main() {
    Val a;
    a.x = 5;
    addTo(&a, 37);
    return a.x;
}
