enum MAGIC = 42;
int g_count = 0;

void bump() {
    g_count = g_count + 1;
}

int main() {
    bump();
    bump();
    bump();
    if (MAGIC != 42) return 1;
    if (g_count != 3) return 2;
    return MAGIC + g_count;
}
