// Test: reading non-first field (verifies offset calculation)
struct Point {
    int x;
    int y;
}

immutable Point P = Point(3, 4);

int main() {
    return P.x + P.y;  // 3 + 4 = 7
}
