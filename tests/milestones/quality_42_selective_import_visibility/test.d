// Quality 42: Selective import should NOT expose unselected symbols
import helper : add;

int main() {
    return sub(10, 5);  // ERROR: sub is not visible
}
