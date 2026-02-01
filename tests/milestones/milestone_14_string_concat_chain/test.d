// Multi-step string concatenation
// Tests that WASM codegen handles chained concats
enum A = "Hello";
enum B = " ";
enum C = "World";
enum D = A ~ B ~ C;  // Chained: (A ~ B) ~ C

void printIt() {
    __writeln(D);
}
enum _ = printIt();

// TODO: Other array concat tests (uncomment to test)
// These should work with the same codegen once array support is added

// int array concat
// enum intArr1 = [1, 2, 3];
// enum intArr2 = [4, 5];
// enum intArr3 = intArr1 ~ intArr2;  // Should be [1, 2, 3, 4, 5]

// Append element to array
// enum withExtra = intArr1 ~ 4;  // Should be [1, 2, 3, 4]

// char array (different from string?)
// enum chars1 = ['a', 'b'];
// enum chars2 = ['c', 'd'];
// enum chars3 = chars1 ~ chars2;

// ubyte array (common for binary data)
// enum bytes1 = [cast(ubyte)0x01, cast(ubyte)0x02];
// enum bytes2 = [cast(ubyte)0x03];
// enum bytes3 = bytes1 ~ bytes2;
