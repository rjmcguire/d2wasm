int tokenize(string input) {
    int count = 0;
    int i = 0;
    while (i < input.length) {
        int c = input[i];
        if (c == cast(int)'{' || c == cast(int)'}' ||
            c == cast(int)':' || c == cast(int)';') {
            count = count + 1;
            i = i + 1;
        } else if (c == cast(int)' ' || c == cast(int)'\n') {
            i = i + 1;
        } else {
            // identifier or value - scan to next delimiter
            while (i < input.length && input[i] != cast(int)'{' &&
                   input[i] != cast(int)'}' && input[i] != cast(int)':' &&
                   input[i] != cast(int)';' && input[i] != cast(int)' ' &&
                   input[i] != cast(int)'\n') {
                i = i + 1;
            }
            count = count + 1;
        }
    }
    return count;
}

int test() {
    return tokenize("body { color: red; }");
    // tokens: body, {, color, :, red, ;, }  = 7
}

enum RESULT = test();
int main() { return RESULT; }
