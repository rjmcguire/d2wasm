int test() {
    string expr_ = "6 5 + 4 *";
    ubyte[] expr = cast(ubyte[])expr_;
    // 6, 5: stack = [6, 5]
    // +: pop 5,6 -> push 11: stack = [11]
    // 4: stack = [11, 4]
    // *: pop 4,11 -> push 44: stack = [44]
    // Result = 44

    int[16] stack;
    int sp = 0;
    int i = 0;
    while (i < expr.length) {
        int c = expr[i];
        if (c == cast(int)' ') {
            i = i + 1;
        } else if (c >= cast(int)'0' && c <= cast(int)'9') {
            // Parse multi-digit number
            int num = 0;
            while (i < expr.length && expr[i] >= cast(int)'0' && expr[i] <= cast(int)'9') {
                num = num * 10 + (expr[i] - cast(int)'0');
                i = i + 1;
            }
            stack[sp] = num;
            sp = sp + 1;
        } else {
            int b = stack[sp - 1]; sp = sp - 1;
            int a = stack[sp - 1]; sp = sp - 1;
            int result = 0;
            if (c == cast(int)'+') result = a + b;
            if (c == cast(int)'-') result = a - b;
            if (c == cast(int)'*') result = a * b;
            stack[sp] = result;
            sp = sp + 1;
            i = i + 1;
        }
    }
    return stack[0];
}

enum RESULT = test();
int main() { return RESULT; }
