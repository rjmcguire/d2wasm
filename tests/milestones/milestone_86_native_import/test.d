// Milestone 86: Native backend import() support
// Use import() inside a function evaluated at compile time

int getFileLength() {
    ubyte[] data = import("data.txt");
    return data.length;
}

// CTFE evaluation - should work with native backend
enum fileLen = getFileLength();

int main() {
    return fileLen;  // 5 ("Hello")
}
