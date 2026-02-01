// Array literal and concat tests
enum arr1 = [1, 2, 3];
enum arr2 = [4, 5];
enum arr3 = arr1 ~ arr2;      // [1, 2, 3, 4, 5]
enum arr4 = arr3 ~ [6, 7];    // [1, 2, 3, 4, 5, 6, 7]

// Char literal test  
enum c = 'x';

// Simple function to verify compilation
int getLength() {
    return 7;  // Length of arr4
}
