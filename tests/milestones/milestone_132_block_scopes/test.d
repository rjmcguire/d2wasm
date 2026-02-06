// Milestone 132: Block scopes - variables go out of scope correctly
// Tests nested scopes and for loop scope

int main() {
    int result = 0;
    
    // Nested block scope
    {
        int a = 10;
        {
            int b = 20;
            result = a + b;  // 30
        }
        // b is out of scope here - can't use it
        result = result + a;  // 40
    }
    // a is out of scope here - can't use it
    
    // For loop scope - i only visible inside loop
    for (int i = 0; i < 3; i++) {
        result = result + i;  // 40+0+1+2 = 43
    }
    // i is out of scope here
    
    return result;  // 43
}
