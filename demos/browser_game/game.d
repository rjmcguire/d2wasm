// Demo 1: Browser-Runnable D
// A simple score tracker that can be called from JavaScript

int score = 0;

int addPoints(int pts) {
    score += pts;
    return score;
}

int getScore() {
    return score;
}

int resetScore() {
    score = 0;
    return 0;
}

// Entry point for standalone testing
int main() {
    addPoints(10);
    addPoints(5);
    return getScore();  // Should return 15
}
