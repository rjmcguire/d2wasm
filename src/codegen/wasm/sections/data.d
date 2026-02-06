/**
 * WASM Data Section Builder
 * 
 * Builds the data section (static data in linear memory).
 */
module codegen.wasm.sections.data;

import codegen.wasm.types : leb128u, leb128s, Op;
import std.array : Appender;

/// Data segment entry
struct DataEntry {
    uint offset;      // Memory offset
    ubyte[] data;     // Raw bytes
}

/**
 * Build the data section content.
 * Returns raw section bytes (without section ID/length prefix).
 */
ubyte[] buildDataSection(const(DataEntry)[] entries) {
    if (entries.length == 0) return null;
    
    Appender!(ubyte[]) section;
    
    // Segment count
    leb128u(section, entries.length);
    
    foreach (entry; entries) {
        // Active segment, memory 0
        section ~= cast(ubyte)0x00;
        
        // Offset expression: i32.const <offset>
        section ~= Op.i32_const;
        leb128s(section, entry.offset);
        section ~= Op.end;
        
        // Data
        leb128u(section, entry.data.length);
        section ~= entry.data;
    }
    
    return section.data;
}
