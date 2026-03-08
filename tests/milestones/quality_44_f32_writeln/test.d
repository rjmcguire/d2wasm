// Test __writeln with f32-typed variables (needs f64_promote_f32 before __ctfe_write_f64)

void test1() {
    float x = 3.5;
    __writeln(x);
}
enum _1 = test1();

void test2() {
    float y = -2.5;
    __writeln(y);
}
enum _2 = test2();
