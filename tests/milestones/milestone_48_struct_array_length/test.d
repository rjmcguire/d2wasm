// Test: arrays as built-in structs - .length property
// String literals are ubyte[] - validates slice struct machinery

int main() {
    string msg = "hello";
    return msg.length;  // 5
}
