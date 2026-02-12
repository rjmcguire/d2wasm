int r = 10;
struct A {
  ~this() { r--; }
}
int test() {
  int x;
//  struct A {
//  ~this() { x = x-1; }
//}
  for (int i=0; i<10; i++) {
//    A b;
A b;
  }
  return x;
}
enum RESULT = test();

int main() { return RESULT; }

