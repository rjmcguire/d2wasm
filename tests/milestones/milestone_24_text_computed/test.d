enum a = 20;
enum b = 2;
enum code = "enum x = " ~ __text(a + b) ~ ";";
mixin(code);

int result() {
    return x;
}
