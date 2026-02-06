// Milestone 136: Codegen uses uniqueLocalId
// Tests that codegen properly resolves variables using unique IDs
// even across nested scopes

int main() {
    int x = 10;  // ID 0
    int result = 0;  // ID 1
    
    {
        int a = 1;  // ID 2
        int b = 2;  // ID 3
        result = x + a + b;  // 10+1+2 = 13
    }
    
    {
        int c = 3;  // ID 4 (different scope, different ID)
        result = result + c;  // 13+3 = 16
    }
    
    // All identifiers resolved via uniqueLocalId during type checking
    return result + x;  // 16+10 = 26
}
