string[] make_strings() {
    string[] arr;
    arr ~= "hello";
    arr ~= "world";
    arr ~= "test";
    return arr;
}

// Core test: enum of string[] type
enum STRS = make_strings();

int sum_lengths() {
    string[] arr = STRS;
    return arr[0].length + arr[1].length + arr[2].length;
}

enum RESULT = sum_lengths();
int main() { return RESULT; }
