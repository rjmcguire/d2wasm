extern(C) int puts(const char* s);

int main() {
    puts("hello\0".ptr);
    return 0;
}
