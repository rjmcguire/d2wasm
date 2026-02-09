/**
 * Milestone 172b: Missing Interface Implementation Error
 */
module test.missing_impl;

interface ISpeak {
    int speak();
}

// Dog doesn't implement speak() - should error
class Dog : ISpeak {
    int bark() { return 42; }
}

int main() { return 0; }
