// Milestone 65: Chained slicing (slice of a slice)
// arr[1..5][1..3] should give elements at indices 2,3 of original

int main() {
    int[] arr = [10, 20, 30, 40, 50, 60];
    
    // First slice: arr[1..5] = [20, 30, 40, 50]
    int[] s1 = arr[1..5];
    
    // Second slice: s1[1..3] = [30, 40]
    int[] s2 = s1[1..3];
    
    // s2[0] should be 30, s2[1] should be 40
    // Return s2[0] + s2[1] = 70
    return s2[0] + s2[1];
}
