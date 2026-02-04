// Milestone 75: import() inside CTFE function

int getDataLength() {
    ubyte[] data = import("data.txt");
    return data.length;
}

// Force CTFE evaluation
enum result = getDataLength();

int main() {
    return result;  // 3 ("XYZ")
}
