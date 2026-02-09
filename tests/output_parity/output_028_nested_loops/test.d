int test() {
    int sum = 0;
    int i = 0;
    while (i < 3) {
        int j = 0;
        while (j < 4) {
            sum = sum + 1;
            j = j + 1;
        }
        i = i + 1;
    }
    return sum;
}

int main() { return test(); }
