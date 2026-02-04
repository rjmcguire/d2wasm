// Milestone 73: import() basic
// Read file at compile time, return its length

enum data = import("data.txt");

int main() {
    return data.length;  // "Hello" = 5 bytes
}
