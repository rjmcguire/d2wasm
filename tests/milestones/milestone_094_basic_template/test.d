// Test basic function template with explicit instantiation

T max(T)(T a, T b) {
    if (a > b) return a;
    return b;
}

int main() {
    return max!int(3, 8);
}
