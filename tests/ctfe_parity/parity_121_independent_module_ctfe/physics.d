module physics;

int velocity(int dist, int time) {
    return dist / time;
}

// CTFE evaluated by physics' own per-module evaluator
enum SPEED = velocity(54, 3);  // 18
