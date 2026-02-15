struct Point {
    int x;
    int y;
    int sum() { return x + y; }
}

enum memberCount = __traits(allMembers, Point).length;
int main() { return memberCount; }
