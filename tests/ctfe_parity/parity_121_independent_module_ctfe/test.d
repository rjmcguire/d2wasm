import shapes;
import physics;

// Both modules define their own enum constants via CTFE.
// Each module's per-module evaluator handles its own constants.
int main() {
    return AREA + SPEED;  // 12 + 18 = 30
}
