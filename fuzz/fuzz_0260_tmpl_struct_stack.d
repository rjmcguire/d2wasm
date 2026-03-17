// EXPECTED: 30
// EXPECTED: 20
// EXPECTED: 10
struct Stack(T) {
    T[10] data;
    int top;

    void push(T val) {
        data[top] = val;
        top++;
    }

    T pop() {
        top--;
        return data[top];
    }
}

int main() {
    Stack!int s;
    s.top = 0;
    s.push(10);
    s.push(20);
    s.push(30);
    __writeln(s.pop());
    __writeln(s.pop());
    __writeln(s.pop());
    return 0;
}
