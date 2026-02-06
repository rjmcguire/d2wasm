// Milestone 134: CompoundStatement gets destructOnExit list
// Tests that type checker tracks variables for RAII destruction
// (Internal annotation - verified by successful compile/run)

int main() {
    int result = 0;
    
    {
        int a = 1;  // Tracked for destruction
        int b = 2;  // Tracked for destruction
        result = a + b;
    }
    // destructOnExit = [a's ID, b's ID] - would destruct b then a
    
    {
        int c = result * 2;  // Tracked
        {
            int d = c + 1;  // Tracked in inner scope
            result = d;
        }
        // Inner destructOnExit = [d's ID]
    }
    // Outer destructOnExit = [c's ID]
    
    return result;  // (1+2)*2+1 = 7
}
