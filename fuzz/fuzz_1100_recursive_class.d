// EXPECTED: 3
// Linked-list-like structure
class Node {
    int val;
    Node next;

    this(int v, Node n) {
        val = v;
        next = n;
    }
}

int length(Node n) {
    int c = 0;
    while (n !is null) {
        c++;
        n = n.next;
    }
    return c;
}

int main() {
    auto list = new Node(1, new Node(2, new Node(3, null)));
    __writeln(length(list));
    return 0;
}
