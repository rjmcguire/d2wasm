module shapes;

int rectArea(int w, int h) {
    return w * h;
}

// CTFE evaluated by shapes' own per-module evaluator
enum AREA = rectArea(3, 4);  // 12
