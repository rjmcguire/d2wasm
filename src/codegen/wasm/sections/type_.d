/**
 * WASM Type Section Builder
 * 
 * Builds the type section containing function signatures.
 */
module codegen.wasm.sections.type_;

import codegen.wasm.types : leb128u, ValType;
import std.array : Appender;

/// Function signature for type section
struct FuncSig {
    ValType[] params;
    ValType[] results;
    
    bool opEquals(const FuncSig other) const {
        return params == other.params && results == other.results;
    }
    
    size_t toHash() const nothrow @safe {
        size_t h = 0;
        foreach (p; params) h = h * 31 + p;
        foreach (r; results) h = h * 31 + r;
        return h;
    }
}

/**
 * Build the type section content.
 * Returns raw section bytes (without section ID/length prefix).
 */
ubyte[] buildTypeSection(const(FuncSig)[] types) {
    if (types.length == 0) return null;
    
    Appender!(ubyte[]) section;
    
    // Type count
    leb128u(section, types.length);
    
    foreach (sig; types) {
        // Function type marker
        section ~= cast(ubyte)0x60;
        
        // Parameters
        leb128u(section, sig.params.length);
        foreach (p; sig.params) {
            section ~= cast(ubyte)p;
        }
        
        // Results
        leb128u(section, sig.results.length);
        foreach (r; sig.results) {
            section ~= cast(ubyte)r;
        }
    }
    
    return section.data;
}
