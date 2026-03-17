int[] globalData;

void bad() {
    int[] local = [1, 2, 3];
    globalData = local;
}

int main() {
    return 0;
}
