int main() {
    int total = 0;
    int i = 0;
    while (i < 10) {
        if (i == 3) {
            i = i + 1;
            continue;
        }
        if (i == 7) {
            break;
        }
        total = total + i;
        i = i + 1;
    }
    return total;  // 0+1+2+4+5+6 = 18
}
