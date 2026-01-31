/**
 * GC Error Example
 * 
 * This file should be rejected by the feature validator
 * because it uses garbage-collected allocation (new operator).
 */

class Node {
    int value;
    Node next;
    
    this(int v) {
        value = v;
        next = null;
    }
    
    void append(int v) {
        if (next is null) {
            next = new Node(v);  // ERROR: GC allocation not supported
        } else {
            next.append(v);
        }
    }
    
    int sum() {
        int result = value;
        if (next !is null) {
            result += next.sum();
        }
        return result;
    }
}

int main() {
    Node root = new Node(1);     // ERROR: GC allocation not supported
    root.append(2);
    root.append(3);
    
    return root.sum();
}