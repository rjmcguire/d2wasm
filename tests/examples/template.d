template Vector(T) {
    struct Vector {
        T[] data;
        
        void push(T item) {
            data ~= item;
        }
    }
}

int main() {
    auto vec = Vector!int();
    vec.push(42);
    return 0;
}