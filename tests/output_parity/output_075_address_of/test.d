struct Box {
    int val;
}

void setVal(Box* b, int v) {
    b.val = v;
}

int main() {
    Box b;
    b.val = 10;
    setVal(&b, 42);
    return b.val;
}
