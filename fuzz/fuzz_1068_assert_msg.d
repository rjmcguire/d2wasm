// STATUS: maybeLater — assert_expression not implemented
// EXPECTED: ok
int main() {
    assert(5 > 3, "five should be greater than three");
    __writeln("ok");
    return 0;
}
