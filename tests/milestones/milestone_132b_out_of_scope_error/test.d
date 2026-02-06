// Milestone 132b: Out-of-scope variable access should error

int main() {
    {
        int x = 10;
    }
    return x;  // ERROR: x is out of scope
}
