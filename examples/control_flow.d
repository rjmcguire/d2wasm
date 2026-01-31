/**
 * Test control flow constructs
 */

// Test if-else
int max(int a, int b) {
    if (a > b) {
        return a;
    } else {
        return b;
    }
}

// Test while loop
int factorial(int n) {
    int result = 1;
    int i = 1;
    
    while (i <= n) {
        result = result * i;
        i = i + 1;
    }
    
    return result;
}

// Test for loop
int sumToN(int n) {
    int sum = 0;
    
    for (int i = 1; i <= n; i = i + 1) {
        sum = sum + i;
    }
    
    return sum;
}

int main() {
    int a = max(5, 10);      // 10
    int fact = factorial(5); // 120 
    int sum = sumToN(10);    // 55
    
    return sum;
}