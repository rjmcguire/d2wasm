// Test: arrays as built-in structs - .length property
// String literals are ubyte[] - validates slice struct machinery

int main() {
    ubyte[] msg = "hello";
    return msg.length;  // 5
}
