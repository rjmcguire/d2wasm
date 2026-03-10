int main() {
    string s = "ab";
    int len = (s ~ "cd").length;  // 4, generic .length on concat result
    if (len != 4) return 1;
    return len;
}
