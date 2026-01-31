class Node {
    int value;
    Node next;
    
    this(int v) {
        value = v;
    }
}

int main() {
    auto node = new Node(42);  // GC allocation
    return node.value;
}