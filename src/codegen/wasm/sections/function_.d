/**
 * WASM Function Section Builder
 * 
 * Builds the function section (type index for each function).
 */
module codegen.wasm.sections.function_;

import codegen.wasm.types : leb128u;
import std.array : Appender;

/**
 * Build the function section content.
 * Returns raw section bytes (without section ID/length prefix).
 * 
 * Params:
 *   typeIndices = Type index for each local function
 */
ubyte[] buildFunctionSection(const(uint)[] typeIndices) {
    if (typeIndices.length == 0) return null;
    
    Appender!(ubyte[]) section;
    
    // Function count
    leb128u(section, typeIndices.length);
    
    foreach (idx; typeIndices) {
        leb128u(section, idx);
    }
    
    return section.data;
}
