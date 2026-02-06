/**
 * WASM Global Section Builder
 * 
 * Builds the global section (global variable declarations).
 */
module codegen.wasm.sections.global;

import codegen.wasm.types : leb128u, leb128s, ValType, Op;
import std.array : Appender;

/// Global variable info
struct GlobalInfo {
    ValType type;
    bool mutable;
    long initValue;
}

/**
 * Build the global section content.
 * Returns raw section bytes (without section ID/length prefix).
 */
ubyte[] buildGlobalSection(const(GlobalInfo)[] globals) {
    if (globals.length == 0) return null;
    
    Appender!(ubyte[]) section;
    
    // Global count
    leb128u(section, globals.length);
    
    foreach (g; globals) {
        // Type
        section ~= cast(ubyte)g.type;
        // Mutability: 0 = const, 1 = mutable
        section ~= cast(ubyte)(g.mutable ? 1 : 0);
        
        // Init expression
        if (g.type == ValType.i32) {
            section ~= Op.i32_const;
            leb128s(section, g.initValue);
        } else if (g.type == ValType.i64) {
            section ~= Op.i64_const;
            leb128s(section, g.initValue);
        }
        section ~= Op.end;
    }
    
    return section.data;
}
