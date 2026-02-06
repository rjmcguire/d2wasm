// Milestone 130: Scope tree with parent pointer lookup
// Tests that variables in outer scopes are visible from inner scopes

int main() {
    int x = 10;
    {
        // Inner scope should see outer x
        int y = x + 5;  // y = 15
        return y;
    }
}
