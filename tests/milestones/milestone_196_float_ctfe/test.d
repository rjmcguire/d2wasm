// Test float/double CTFE support

// Test 1: float literal
enum PI = 3.14159265;
void test1() { __writeln(PI); }
enum _1 = test1();

// Test 2: float arithmetic
enum TAU = PI * 2.0;
void test2() { __writeln(TAU); }
enum _2 = test2();

// Test 3: float negation
enum NEG_PI = -3.14159265;
void test3() { __writeln(NEG_PI); }
enum _3 = test3();
