enum n = 7;
enum code = "enum x = " ~ __text(n) ~ ";";
mixin(code);

int result() {
    return x;
}
