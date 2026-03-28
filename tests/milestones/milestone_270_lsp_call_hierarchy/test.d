int leaf() { return 1; }

int middle() { return leaf(); }

int main() {
    return middle();
}
