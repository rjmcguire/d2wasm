/**
 * Template Error Example
 * 
 * This file should be rejected by the feature validator
 * because it uses templates, which are not supported.
 */

template Vector(T) {
    struct Vector {
        T[] data;
        size_t length;
        
        void push(T item) {
            data ~= item;
            length++;
        }
        
        T get(size_t index) {
            return data[index];
        }
    }
}

T max(T)(T a, T b) {
    return a > b ? a : b;
}

int main() {
    auto intVector = Vector!int();
    intVector.push(42);
    intVector.push(24);
    
    int result = max!int(intVector.get(0), intVector.get(1));
    return result;
}