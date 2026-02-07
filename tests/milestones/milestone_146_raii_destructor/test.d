/**
 * Milestone 146: RAII Destructor Calls
 *
 * Tests that struct destructors are parsed and called.
 * Note: This is a simplified test that just verifies the 
 * destructor mechanism compiles and runs without error.
 */

struct Resource {
    int value;
    
    ~this() {
        // Destructor body - sets value to magic number
        value = 99;
    }
}

// Test basic destructor at scope exit
int testScopeExit() {
    {
        Resource r;
        r.value = 42;
    }
    // Resource's destructor was called when 'r' went out of scope
    return 0;
}

// Test destructor on early return
int testEarlyReturn(int x) {
    Resource r;
    r.value = x;
    if (x > 0) {
        return 1;  // Destructor called before this return
    }
    return 0;  // Destructor called before this return too
}

// Entry point
int test() {
    int result = testScopeExit();
    if (result != 0) return result;
    
    result = testEarlyReturn(5);
    if (result != 1) return 10;
    
    result = testEarlyReturn(0);
    if (result != 0) return 11;
    
    return 0;
}
