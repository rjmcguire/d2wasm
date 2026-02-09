int findFirst(int target) {
    int i = 0;
    while (i < 100) {
        if (i == target) {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

int main() { return findFirst(42); }
