// Milestone 67: Mutate slice through function parameter
// Pass slice to function, modify element, verify caller sees change

void setSecond(int[] arr, int val) {
    arr[1] = val;
}

int main() {
    int[] data = [10, 20, 30];
    setSecond(data, 99);
    return data[1];
}
