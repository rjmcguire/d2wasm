int main() {
    int x = 5;
    x++;        // valid: variable is an lvalue
    (x + 1)++; // invalid: expression is not an lvalue
    return x;
}
