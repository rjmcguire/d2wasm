int main() {
    // int -> float (f32_convert_i32_s) -> int (i32_trunc_f32_s)
    int i = 7;
    float f = cast(float) i;           // 7.0f
    int back = cast(int) f;            // 7

    // double -> float (f32_demote_f64) -> double (f64_promote_f32)
    double d = 3.5;
    float narrowed = cast(float) d;    // 3.5f
    double widened = cast(double) narrowed; // 3.5

    // float arithmetic after cast
    float f2 = cast(float)(i + 3);     // 10.0f
    int prod = cast(int)(f * f2);      // i32_trunc_f32_s(70.0f) = 70

    // long -> float (f32_convert_i64_s) -> long (i64_trunc_f32_s)
    long l = 42;
    float fl = cast(float) l;          // 42.0f
    long lb = cast(long) fl;           // 42

    // Accumulate: 7 + 3 + 70 + 42 = 122
    return back + cast(int) widened + prod + cast(int) lb;
}
