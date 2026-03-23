// STATUS: wontfix — braceless if not parsed
// EXPECTED: yes
int main() {
    if (true) __writeln("yes");
    return 0;
}
