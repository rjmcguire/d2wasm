/**
 * Milestone 170: Parse Interface Declaration
 */
module test.interface_parse;

interface ISpeak {
    int speak();
}

interface IWalk {
    int walk();
    int run();
}

// Just test that interfaces parse - no implementation yet
int main() {
    return 42;
}
