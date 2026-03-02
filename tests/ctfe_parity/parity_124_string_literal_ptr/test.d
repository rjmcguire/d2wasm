// Parity 124: string literal .ptr returns a valid pointer
// "hello".ptr should give a char* pointing to the string data

int main() {
    char* p = "hello".ptr;
    // Dereference to verify it points to valid data
    char c = *p;
    return cast(int)c;  // 'h' == 104
}
