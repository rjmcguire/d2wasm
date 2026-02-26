// Milestone 202: Renamed import binding — `plus` maps to `add`
import helper : plus = add;

int main() {
    return plus(35, 7);  // 42
}
