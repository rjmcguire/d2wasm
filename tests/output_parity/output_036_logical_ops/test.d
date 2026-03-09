int main() {
    int score = 0;
    bool t = true;
    bool f = false;

    if (!f) score = score + 1;
    if (!(!t)) score = score + 1;

    return score;
}
