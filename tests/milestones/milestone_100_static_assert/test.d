// Static assert - compile-time assertion
enum SIZE = 4;

static assert(SIZE == 4, "SIZE must be 4");
static assert(SIZE > 0);  // no message

int result() {
    return SIZE;
}
