import shapes;

int compute(Rect r) {
    return r.area() + perimeterRect(r) + MAX_SIDES;
}

int main() {
    Rect r;
    r.w = 3;
    r.h = 4;
    return compute(r);  // area=12, perimeter=14, MAX_SIDES=100 → 126
}
