// Milestone 135: Return statement gets unwindChain
// Tests that return statement tracks all scopes for RAII unwinding

int foo(int n) {
    int a = 1;
    {
        int b = 2;
        {
            int c = 3;
            if (n > 0) {
                int d = 4;
                // Return from deeply nested scope
                // unwindChain = [[d], [c], [b], [a]] (innermost first)
                return a + b + c + d;  // 1+2+3+4 = 10
            }
        }
        return a + b;  // 3
    }
}

int main() {
    return foo(1);  // 10
}
