extern(C) int puts(const char* s);

char* toStringz(string s) {
    return (s ~ "\0").ptr;
}

int main() {
    char* cstr = "hello".toStringz();
    puts(cstr);
    return 0;
}
