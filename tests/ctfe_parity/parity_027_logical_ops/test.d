int test() {
    int score = 0;
    bool t = true;
    bool f = false;
    
    // Logical NOT
    if (!f) score = score + 1;
    if (!(!t)) score = score + 1;
    
    return score;  // 2
}

enum RESULT = test();
int main() { return RESULT; }
