// Milestone 64: Multiple appends trigger reallocation
// Start with capacity 3, append 10 elements to force growth cascade

int main() {
    int[] arr = [1, 2, 3];
    
    // Initial: length=3, capacity=3
    // These appends should trigger reallocation(s)
    arr ~= 4;   // length=4, needs growth
    arr ~= 5;
    arr ~= 6;
    arr ~= 7;
    arr ~= 8;
    arr ~= 9;
    arr ~= 10;
    arr ~= 11;
    arr ~= 12;
    arr ~= 13;
    
    // Verify: length should be 13, last element should be 13
    int len = arr.length;
    int last = arr[12];
    
    // Return length * 100 + last = 1313
    return len * 100 + last;
}
