struct Container {
    int[] data;
}

void storeInto(Container* c) {
    int[] local = [1, 2, 3];
    c.data = local;
}

int main() {
    return 0;
}
