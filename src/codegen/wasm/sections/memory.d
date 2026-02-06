/**
 * WASM Memory Section Builder
 * 
 * Builds the memory section (linear memory declaration).
 */
module codegen.wasm.sections.memory;

import codegen.wasm.types : leb128u;
import std.array : Appender;

/**
 * Build the memory section content.
 * Returns raw section bytes (without section ID/length prefix).
 * 
 * Params:
 *   minPages = Minimum memory pages (64KB each)
 *   maxPages = Maximum memory pages (null = no maximum)
 */
ubyte[] buildMemorySection(uint minPages, uint* maxPages = null) {
    Appender!(ubyte[]) section;
    
    // 1 memory
    leb128u(section, 1);
    
    if (maxPages !is null) {
        // Limits with max
        section ~= cast(ubyte)0x01;  // flags: has max
        leb128u(section, minPages);
        leb128u(section, *maxPages);
    } else {
        // Limits without max
        section ~= cast(ubyte)0x00;  // flags: no max
        leb128u(section, minPages);
    }
    
    return section.data;
}
