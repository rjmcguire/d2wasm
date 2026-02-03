// Milestone 68: Build slice and sum with loop
// Create slice, append values, iterate and sum

int main() {
    int[] arr = [1, 2, 3];
    arr ~= 4;
    arr ~= 5;
    
    // Sum all elements: 1+2+3+4+5 = 15
    int sum = 0;
    int i = 0;
    while (i < arr.length) {
        sum = sum + arr[i];
        i = i + 1;
    }
    
    return sum;
}
