// Test: arrays as built-in structs - .length property
// This validates that the string type uses struct field access machinery

immutable string MSG = "hello";

int main() {
    return cast(int)MSG.length;  // 5
}
