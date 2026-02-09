/**
 * Milestone 174: Fat Pointers
 * Interface refs are 8 bytes: {obj_ptr, itable_ptr}
 */
module test.fat_pointers;

interface ISpeak {
    int speak();
}

class Dog : ISpeak {
    int x;
    int speak() { return 42; }
}

int main() {
    Dog d;
    ISpeak s = d;  // Creates fat pointer
    return s.speak();  // Dispatch through itable -> 42
}
