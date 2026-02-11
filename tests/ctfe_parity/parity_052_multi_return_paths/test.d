int collatzSteps(int n) {
    int steps = 0;
    while (n != 1) {
        if (n % 2 == 0) {
            n = n / 2;
        } else {
            n = n * 3 + 1;
        }
        steps = steps + 1;
    }
    return steps;
}

int test() {
    // collatz(6): 6->3->10->5->16->8->4->2->1 = 8 steps
    // collatz(7): 7->22->11->34->17->52->26->13->40->20->10->5->16->8->4->2->1 = 16 steps
    return collatzSteps(6) + collatzSteps(7);  // 8 + 16 = 24
}

enum RESULT = test();
int main() { return RESULT; }
