string hello() {
    return "hello";
}

int main() {
    string s = hello();
    return cast(int) s.length;
}
