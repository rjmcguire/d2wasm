// Demo 4: Embedded Data
// Use import() to embed file contents at compile time

// Embed a shader file directly into the WASM binary
enum shaderSource = import("shader.glsl");

// Embed a data file
enum dataFile = import("data.bin");

// Get the embedded shader length
int getShaderLength() {
    return shaderSource.length;
}

// Get a byte from the data file
int getDataByte(int index) {
    if (index < 0 || index >= dataFile.length) {
        return -1;
    }
    return dataFile[index];
}

int main() {
    // Return shader length as a simple test
    return getShaderLength();
}
