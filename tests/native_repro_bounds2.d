// Test cast(ubyte[]) without large struct
int main() {
    string hello = "Hello";
    ubyte[] bytes = cast(ubyte[]) hello;
    return bytes[0];
}
