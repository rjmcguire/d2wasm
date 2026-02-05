// Static assert that fails
enum VALUE = 10;

static assert(VALUE < 5, "VALUE must be less than 5");

int result() {
    return VALUE;
}
