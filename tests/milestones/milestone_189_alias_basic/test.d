// Test basic type alias: alias myint = int;

alias myint = int;

int addOne(myint x) {
    return x + 1;
}

int main() {
    myint x = 41;
    return addOne(x);  // 42
}
