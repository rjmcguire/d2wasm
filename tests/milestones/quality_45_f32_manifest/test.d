enum float PI = 3.14;
enum float HALF = 0.5;

int main() {
    float x = PI;           // manifest constant typed as Float32
    float y = PI * HALF;    // arithmetic on manifest constants
    // PI=3.14, HALF=0.5, PI*HALF=1.57, sum=4.71 -> truncated to 4
    return cast(int)(x + y);
}
