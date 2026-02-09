int test() {
    int score = 0;
    if (5 == 5) score = score + 1;
    if (5 != 6) score = score + 1;
    if (3 < 5) score = score + 1;
    if (5 > 3) score = score + 1;
    if (5 <= 5) score = score + 1;
    if (5 >= 5) score = score + 1;
    return score;
}

int main() { return test(); }
