// EXPECTED: try
// EXPECTED: finally
int main() {
    try {
        __writeln("try");
    } finally {
        __writeln("finally");
    }
    return 0;
}
