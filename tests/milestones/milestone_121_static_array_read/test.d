// Milestone 121: Local static array declaration + read
// Tests:
// - Static array declaration (int[4])
// - Shadow stack allocation for static arrays
// - Reading elements via indexing

int main() {
    int[4] arr;      // Declare on shadow stack (16 bytes)
    return arr[0];   // Read element (zero-initialized)
}
