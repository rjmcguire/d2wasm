// STATUS: maybeLater — assert_expression not implemented
// EXPECTED: ok
int main() {
    assert(1 + 1 == 2);
    assert(true);
    __writeln("ok");
    return 0;
}
