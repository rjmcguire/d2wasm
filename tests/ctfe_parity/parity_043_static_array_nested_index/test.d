int getIndex(int x) {
    return x + 1;
}

int test() {
    int[5] data = [10, 20, 30, 40, 50];
    int[3] indices = [0, 2, 4];

    // Index with a computed value
    int i = getIndex(0);  // 1
    int val = data[i];    // data[1] = 20

    // Index with another array's element
    int j = indices[2];   // 4
    val = val + data[j];  // 20 + data[4] = 20 + 50 = 70

    return val;  // 70
}

enum RESULT = test();
int main() { return RESULT; }
