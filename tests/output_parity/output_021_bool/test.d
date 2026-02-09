int test() {
    bool t = true;
    bool f = false;
    int score = 0;
    if (t) score = score + 1;
    if (!f) score = score + 1;
    return score;
}

int main() { return test(); }
