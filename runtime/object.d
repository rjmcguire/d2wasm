// runtime/object.d — auto-imported before user code

bool stringEqual(string a_, string b_) {
    ubyte[] a = cast(ubyte[])a_;
    ubyte[] b = cast(ubyte[])b_;
    if (a.length != b.length) return false;
    int i = 0;
    while (i < a.length) {
        if (a[i] != b[i]) return false;
        i = i + 1;
    }
    return true;
}

int indexOf(string s_, char c) {
    ubyte[] s = cast(ubyte[])s_;
    int i = 0;
    while (i < s.length) {
        if (s[i] == cast(int)c) return i;
        i = i + 1;
    }
    return -1;
}

int stringIndexOf(string haystack_, string needle_) {
    ubyte[] haystack = cast(ubyte[])haystack_;
    ubyte[] needle = cast(ubyte[])needle_;
    if (needle.length == 0) return 0;
    if (haystack.length < needle.length) return -1;
    int limit = haystack.length - needle.length + 1;
    int i = 0;
    while (i < limit) {
        bool match = true;
        int j = 0;
        while (j < needle.length) {
            if (haystack[i + j] != needle[j]) {
                match = false;
                break;
            }
            j = j + 1;
        }
        if (match) return i;
        i = i + 1;
    }
    return -1;
}

bool isDigit(char c) {
    return cast(int)c >= 48 && cast(int)c <= 57;
}

bool isWhitespace(char c) {
    return cast(int)c == 32 || cast(int)c == 9 || cast(int)c == 10 || cast(int)c == 13;
}

// Checked shift operators — trap on out-of-range shift amounts
T opShiftLeft(T)(T value, int amount) {
    if (amount < 0 || amount >= 32)
        __intrinsic_unreachable();
    return __intrinsic_shl(value, amount);
}

T opShiftRight(T)(T value, int amount) {
    if (amount < 0 || amount >= 32)
        __intrinsic_unreachable();
    return __intrinsic_shr_s(value, amount);
}

T opUnsignedShiftRight(T)(T value, int amount) {
    if (amount < 0 || amount >= 32)
        __intrinsic_unreachable();
    return __intrinsic_shr_u(value, amount);
}
