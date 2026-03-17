// EXPECTED: 3
struct P { int x; int y; }

int main() {
    P[3] pts;
    pts[0] = P(1,0); pts[1] = P(0,1); pts[2] = P(1,1);
    int c = 0;
    for (int i = 0; i < 3; i++) c += pts[i].x + pts[i].y;
    __writeln(c);
    return 0;
}
