int counter = 0;

int test() {
    counter = counter + 1;
    return counter;
}

enum RESULT = test();
int main() { return RESULT; }
