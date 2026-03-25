// Bug: when a large struct precedes a slice variable, emitStoreLocal32 uses
// the large-offset path which clobbers x9 via emitComputeSPOffset.  The slice
// copy loop (ubyte[] b = cast(ubyte[]) s) held the source pointer in x9,
// so after the first store x9 pointed to the DESTINATION, corrupting the
// length/capacity fields with zeros → bounds-check failure on first index.

struct BigBuffer {
    int[4096] data;   // 16 KB — pushes subsequent locals past the imm12 threshold
    int len;
}

int main() {
    BigBuffer buf;
    buf.len = 0;

    // String → ubyte[] cast requires copying the slice struct.
    // With buf on the stack first, the destination offset exceeds 16 KB,
    // triggering the large-offset codepath in emitStoreLocal32.
    string hello = "Hello";
    ubyte[] bytes = cast(ubyte[]) hello;

    // If the copy preserved ptr/len/cap correctly, indexing works.
    int sum = 0;
    int i = 0;
    while (i < 5) {
        sum = sum + cast(int) bytes[i];
        i = i + 1;
    }

    // 'H'=72 'e'=101 'l'=108 'l'=108 'o'=111  → 500
    if (sum != 500) return 1;

    // Also verify the original string slice still works.
    ubyte[] h2 = cast(ubyte[]) hello;
    if (cast(int) h2[0] != 72) return 2;

    return 42;
}
