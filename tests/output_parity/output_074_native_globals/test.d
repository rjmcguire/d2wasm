int g_counter = 0;
int g_flag = 0;

void increment() {
    g_counter = g_counter + 1;
}

void setFlag(int val) {
    g_flag = val;
}

int getCounter() {
    return g_counter;
}

int main() {
    increment();
    increment();
    increment();
    setFlag(42);
    return getCounter() + g_flag;
}
