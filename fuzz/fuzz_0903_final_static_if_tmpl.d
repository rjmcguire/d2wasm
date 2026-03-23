// STATUS: maybeLater — static if not parsed in function bodies
// EXPECTED: int
T identify(T)(T x) {
    static if (__traits(isIntegral, T)) {
        __writeln("int");
    } else {
        __writeln("other");
    }
    return x;
}

int main() {
    identify!int(5);
    return 0;
}
