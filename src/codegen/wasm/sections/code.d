/**
 * WASM Code Section Builder
 * 
 * Builds the code section (function bodies).
 */
module codegen.wasm.sections.code;

import codegen.wasm.types : leb128u;
import std.array : Appender;

/**
 * Build the code section content.
 * Returns raw section bytes (without section ID/length prefix).
 * 
 * Params:
 *   bodies = Pre-built function bodies (each includes locals + code + end)
 */
ubyte[] buildCodeSection(const(ubyte[])[] bodies) {
    if (bodies.length == 0) return null;
    
    Appender!(ubyte[]) section;
    
    // Function count
    leb128u(section, bodies.length);
    
    foreach (body_; bodies) {
        // Body size
        leb128u(section, body_.length);
        section ~= body_;
    }
    
    return section.data;
}
