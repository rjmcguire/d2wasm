// Milestone 74: import() content access
// Index into imported bytes

enum data = import("data.txt");

int main() {
    // "ABCDE" -> data[0]='A'=65, data[2]='C'=67
    return data[0] + data[2];  // 65 + 67 = 132
}
