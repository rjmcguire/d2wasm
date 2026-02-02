enum name = "x";
enum value = "42";
enum code = "int " ~ name ~ " = " ~ value ~ ";";
mixin(code);

int result() {
    return x;
}
