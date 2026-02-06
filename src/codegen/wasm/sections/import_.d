/**
 * WASM Import Section Builder
 * 
 * Builds the import section for external function imports.
 */
module codegen.wasm.sections.import_;

import codegen.wasm.types : leb128u;
import std.array : Appender;

/// Imported function info
struct ImportInfo {
    string moduleName;   // WASM module (e.g., "env", "console")
    string fieldName;    // Function name
    uint typeIndex;      // Index into type section
}

/**
 * Build the import section content.
 * Returns raw section bytes (without section ID/length prefix).
 */
ubyte[] buildImportSection(const(ImportInfo)[] imports) {
    if (imports.length == 0) return null;
    
    Appender!(ubyte[]) section;
    
    // Import count
    leb128u(section, imports.length);
    
    foreach (imp; imports) {
        // Module name (length-prefixed string)
        leb128u(section, imp.moduleName.length);
        section ~= cast(ubyte[])imp.moduleName;
        
        // Field name (length-prefixed string)
        leb128u(section, imp.fieldName.length);
        section ~= cast(ubyte[])imp.fieldName;
        
        // Import kind: 0x00 = function
        section ~= cast(ubyte)0x00;
        
        // Type index
        leb128u(section, imp.typeIndex);
    }
    
    return section.data;
}
