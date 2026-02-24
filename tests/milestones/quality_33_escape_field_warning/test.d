struct Holder {
    int* ptr;
}

void bad() {
    int local = 99;
    Holder h;
    h.ptr = &local;
}

int main() {
    return 0;
}
