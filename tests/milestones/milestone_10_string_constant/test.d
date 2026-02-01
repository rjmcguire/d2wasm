// For now, just test we can have a string and get its length
immutable string MSG = "hello";

int getLength() {
    return cast(int)MSG.length;
}
