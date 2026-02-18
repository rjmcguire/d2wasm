struct IntStack {
    int[] data;
    int size;

    void push(int v) {
        data ~= v;
        size = size + 1;
    }

    int top() {
        return data[size - 1];
    }

    int length() {
        return size;
    }
}

int main() {
    IntStack s;
    s.push(10);
    s.push(20);
    s.push(30);
    return s.top() + s.length();  // 30 + 3 = 33
}
