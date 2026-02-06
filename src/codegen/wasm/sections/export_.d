/**
 * WASM Export Section Builder
 * 
 * Builds the export section (exported functions, memory, globals).
 */
module codegen.wasm.sections.export_;

import codegen.wasm.types : leb128u, ExportKind;
import std.array : Appender;

/// Function export info
struct FuncExport {
    string name;
    uint index;      // Absolute function index (imports + locals)
}

/// Global export info
struct GlobalExport {
    string name;
    uint index;
}

/**
 * Build the export section content.
 * Returns raw section bytes (without section ID/length prefix).
 * 
 * Params:
 *   funcExports = Functions to export
 *   exportMemory = Whether to export memory as "memory"
 *   globalExports = Globals to export
 */
ubyte[] buildExportSection(
    const(FuncExport)[] funcExports,
    bool exportMemory = true,
    const(GlobalExport)[] globalExports = null
) {
    Appender!(ubyte[]) section;
    
    // Count exports
    size_t exportCount = funcExports.length;
    if (exportMemory) exportCount++;
    exportCount += globalExports.length;
    
    if (exportCount == 0) return null;
    
    leb128u(section, exportCount);
    
    // Export functions
    foreach (f; funcExports) {
        leb128u(section, f.name.length);
        section ~= cast(ubyte[])f.name;
        section ~= cast(ubyte)ExportKind.func;
        leb128u(section, f.index);
    }
    
    // Export memory
    if (exportMemory) {
        string memName = "memory";
        leb128u(section, memName.length);
        section ~= cast(ubyte[])memName;
        section ~= cast(ubyte)ExportKind.memory;
        leb128u(section, 0);  // Memory index 0
    }
    
    // Export globals
    foreach (g; globalExports) {
        leb128u(section, g.name.length);
        section ~= cast(ubyte[])g.name;
        section ~= cast(ubyte)ExportKind.global;
        leb128u(section, g.index);
    }
    
    return section.data;
}
