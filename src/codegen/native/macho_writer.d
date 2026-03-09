/**
 * Mach-O Object File Writer (ARM64)
 *
 * Produces MH_OBJECT .o files for the ARM64 architecture.
 * Handles: header, segments, sections, symbol table, string table, relocations.
 */
module codegen.native.macho_writer;

// ========== Mach-O Constants ==========

enum : uint {
    MH_MAGIC_64    = 0xFEED_FACF,
    MH_OBJECT      = 0x1,

    CPU_TYPE_ARM64      = 0x0100_000C,  // CPU_TYPE_ARM | CPU_ARCH_ABI64
    CPU_SUBTYPE_ALL     = 0x0000_0000,

    // Load command types
    LC_SEGMENT_64  = 0x19,
    LC_SYMTAB      = 0x02,
    LC_DYSYMTAB    = 0x0B,

    // Section types and attributes
    S_REGULAR      = 0x0,
    S_ATTR_PURE_INSTRUCTIONS = 0x8000_0000,
    S_ATTR_SOME_INSTRUCTIONS = 0x0000_0400,

    // nlist_64 type bits
    N_EXT   = 0x01,
    N_UNDF  = 0x00,
    N_SECT  = 0x0E,

    // Relocation types for ARM64
    ARM64_RELOC_BRANCH26  = 2,
    ARM64_RELOC_PAGE21    = 3,
    ARM64_RELOC_PAGEOFF12 = 4,
}

// ========== Mach-O Structures ==========

align(1) struct MachHeader64 {
    uint magic = MH_MAGIC_64;
    uint cpuType = CPU_TYPE_ARM64;
    uint cpuSubtype = CPU_SUBTYPE_ALL;
    uint fileType = MH_OBJECT;
    uint nCmds;
    uint sizeOfCmds;
    uint flags = 0;
    uint reserved = 0;
}
static assert(MachHeader64.sizeof == 32);

align(1) struct SegmentCommand64 {
    uint cmd = LC_SEGMENT_64;
    uint cmdSize;
    char[16] segName = 0;
    ulong vmAddr = 0;
    ulong vmSize;
    ulong fileOff;
    ulong fileSize;
    uint maxProt = 7;  // rwx
    uint initProt = 7;
    uint nSections;
    uint flags = 0;
}
static assert(SegmentCommand64.sizeof == 72);

align(1) struct Section64 {
    char[16] sectName = 0;
    char[16] segName = 0;
    ulong addr;
    ulong size;
    uint fileOffset;
    uint align_ = 2;       // 2^2 = 4-byte alignment (instruction alignment)
    uint relocOffset = 0;
    uint nRelocs = 0;
    uint flags = 0;
    uint reserved1 = 0;
    uint reserved2 = 0;
    uint reserved3 = 0;
}
static assert(Section64.sizeof == 80);

align(1) struct SymtabCommand {
    uint cmd = LC_SYMTAB;
    uint cmdSize = 24;
    uint symOff;
    uint nSyms;
    uint strOff;
    uint strSize;
}
static assert(SymtabCommand.sizeof == 24);

align(1) struct DysymtabCommand {
    uint cmd = LC_DYSYMTAB;
    uint cmdSize = 80;
    uint iLocalSym;
    uint nLocalSym;
    uint iExtDefSym;
    uint nExtDefSym;
    uint iUndefSym;
    uint nUndefSym;
    uint tocOff = 0;
    uint nToc = 0;
    uint modTabOff = 0;
    uint nModTab = 0;
    uint extRefSymOff = 0;
    uint nExtRefSyms = 0;
    uint indirectSymOff = 0;
    uint nIndirectSyms = 0;
    uint extRelocOff = 0;
    uint nExtReloc = 0;
    uint localRelocOff = 0;
    uint nLocalReloc = 0;
}
static assert(DysymtabCommand.sizeof == 80);

align(1) struct Nlist64 {
    uint strIndex;
    ubyte type;
    ubyte sect;      // 1-based section number
    ushort desc = 0;
    ulong value;
}
static assert(Nlist64.sizeof == 16);

align(1) struct RelocationInfo {
    int address;         // offset in section
    uint packed;         // symbolnum:24, pcrel:1, length:2, extern:1, type:4
}
static assert(RelocationInfo.sizeof == 8);

// ========== Relocation Type ==========

enum RelocType {
    branch26,
    page21,
    pageoff12,
}

struct PendingReloc {
    uint sectionIndex;   // which section (0-based)
    uint offset;         // offset within section
    string symbol;       // symbol name
    RelocType type;
}

// ========== MachO Writer ==========

class MachOWriter {
    // Sections
    private const(ubyte)[] textCode;
    private const(ubyte)[] dataConst;

    // Symbols: (name, sectionIndex 1-based, offset, isExported)
    private SymbolEntry[] symbols;
    private PendingReloc[] relocs;

    // String table
    private ubyte[] stringTable;
    private uint[string] stringOffsets;

    private struct SymbolEntry {
        string name;
        ubyte sectionIndex; // 1-based (0 = N_UNDF)
        ulong value;
        bool isExternal;    // N_EXT flag
    }

    this() {
        // String table starts with a null byte
        stringTable = [0];
    }

    /// Set the __TEXT,__text section content
    void setTextSection(const(ubyte)[] code) {
        textCode = code;
    }

    /// Set the __DATA,__const section content (Phase 3+)
    void setDataConstSection(const(ubyte)[] data) {
        dataConst = data;
    }

    /// Add an exported symbol (defined in a section)
    void addExportedSymbol(string name, ubyte sectionIndex, ulong offset) {
        symbols ~= SymbolEntry(name, sectionIndex, offset, true);
    }

    /// Add a local symbol (not visible outside this .o)
    void addLocalSymbol(string name, ubyte sectionIndex, ulong offset) {
        symbols ~= SymbolEntry(name, sectionIndex, offset, false);
    }

    /// Add an external (undefined) symbol reference
    void addExternalSymbol(string name) {
        symbols ~= SymbolEntry(name, 0, 0, true);
    }

    /// Add a relocation entry
    void addRelocation(uint sectionIndex, uint offset, string symbol, RelocType type) {
        relocs ~= PendingReloc(sectionIndex, offset, symbol, type);
    }

    /// Produce the final .o file bytes
    ubyte[] finalize() {
        // Count sections
        uint nSections = 1; // always have __text
        if (dataConst.length > 0) nSections++;

        // Sort symbols: locals first, then external defined, then undefined
        SymbolEntry[] locals, extDef, undef;
        foreach (ref s; symbols) {
            if (s.sectionIndex == 0)
                undef ~= s;
            else if (!s.isExternal)
                locals ~= s;
            else
                extDef ~= s;
        }
        auto sortedSymbols = locals ~ extDef ~ undef;

        // Build string table and record offsets
        uint[string] symNameToIndex;
        foreach (i, ref s; sortedSymbols) {
            addString(s.name);
            symNameToIndex[s.name] = cast(uint)i;
        }

        // Build relocation entries
        RelocationInfo[] relocEntries;
        foreach (ref r; relocs) {
            uint symIdx = symNameToIndex.get(r.symbol, 0);
            bool isExtern = true;
            ubyte length = 2; // 4 bytes (2^2)
            bool pcrel = false;
            uint rtype;

            final switch (r.type) {
                case RelocType.branch26:
                    rtype = ARM64_RELOC_BRANCH26;
                    pcrel = true;
                    break;
                case RelocType.page21:
                    rtype = ARM64_RELOC_PAGE21;
                    pcrel = true;
                    break;
                case RelocType.pageoff12:
                    rtype = ARM64_RELOC_PAGEOFF12;
                    pcrel = false;
                    break;
            }

            uint packed = (symIdx & 0x00FF_FFFF)
                        | (pcrel ? (1 << 24) : 0)
                        | (cast(uint)length << 25)
                        | (isExtern ? (1 << 27) : 0)
                        | (rtype << 28);

            relocEntries ~= RelocationInfo(cast(int)r.offset, packed);
        }

        // Layout calculation
        uint headerSize = cast(uint)MachHeader64.sizeof;
        uint segCmdSize = cast(uint)(SegmentCommand64.sizeof + nSections * Section64.sizeof);
        uint symtabCmdSize = cast(uint)SymtabCommand.sizeof;
        uint dysymtabCmdSize = cast(uint)DysymtabCommand.sizeof;
        uint totalCmdSize = segCmdSize + symtabCmdSize + dysymtabCmdSize;

        uint sectionDataStart = headerSize + totalCmdSize;

        // Section offsets
        uint textOffset = sectionDataStart;
        uint textSize = cast(uint)textCode.length;

        uint dataConstOffset = textOffset + textSize;
        uint dataConstSize = cast(uint)dataConst.length;

        // Relocations follow section data
        uint relocStart = dataConstOffset + dataConstSize;
        uint relocSize = cast(uint)(relocEntries.length * RelocationInfo.sizeof);

        // Symbol table follows relocations
        uint symtabOffset = relocStart + relocSize;
        uint nSyms = cast(uint)sortedSymbols.length;
        uint symtabSize = cast(uint)(nSyms * Nlist64.sizeof);

        // String table follows symbol table
        uint strtabOffset = symtabOffset + symtabSize;
        uint strtabSize = cast(uint)stringTable.length;

        uint totalSize = strtabOffset + strtabSize;

        // Build the file
        auto result = new ubyte[totalSize];

        // 1. Mach-O header
        MachHeader64 header;
        header.nCmds = 3; // LC_SEGMENT_64, LC_SYMTAB, LC_DYSYMTAB
        header.sizeOfCmds = totalCmdSize;
        writeStruct(result, 0, header);

        // 2. LC_SEGMENT_64
        SegmentCommand64 segCmd;
        segCmd.cmdSize = segCmdSize;
        segCmd.vmSize = textSize + dataConstSize;
        segCmd.fileOff = sectionDataStart;
        segCmd.fileSize = textSize + dataConstSize;
        segCmd.nSections = nSections;
        writeStruct(result, headerSize, segCmd);

        // 3. __TEXT,__text section
        uint sectOffset = cast(uint)(headerSize + SegmentCommand64.sizeof);
        Section64 textSect;
        setName(textSect.sectName, "__text");
        setName(textSect.segName, "__TEXT");
        textSect.addr = 0;
        textSect.size = textSize;
        textSect.fileOffset = textOffset;
        textSect.align_ = 2; // 4-byte aligned (instructions)
        textSect.flags = S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS;

        // Attach relocations to __text section
        if (relocEntries.length > 0) {
            textSect.relocOffset = relocStart;
            textSect.nRelocs = cast(uint)relocEntries.length;
        }

        writeStruct(result, sectOffset, textSect);
        sectOffset += cast(uint)Section64.sizeof;

        // 4. __DATA,__const section (if present)
        if (dataConst.length > 0) {
            Section64 dataSect;
            setName(dataSect.sectName, "__const");
            setName(dataSect.segName, "__DATA");
            dataSect.addr = textSize; // vm address follows text
            dataSect.size = dataConstSize;
            dataSect.fileOffset = dataConstOffset;
            dataSect.align_ = 3; // 8-byte aligned
            dataSect.flags = S_REGULAR;
            writeStruct(result, sectOffset, dataSect);
        }

        // 5. LC_SYMTAB
        SymtabCommand symtab;
        symtab.symOff = symtabOffset;
        symtab.nSyms = nSyms;
        symtab.strOff = strtabOffset;
        symtab.strSize = strtabSize;
        writeStruct(result, headerSize + segCmdSize, symtab);

        // 6. LC_DYSYMTAB
        DysymtabCommand dysymtab;
        dysymtab.iLocalSym = 0;
        dysymtab.nLocalSym = cast(uint)locals.length;
        dysymtab.iExtDefSym = cast(uint)locals.length;
        dysymtab.nExtDefSym = cast(uint)extDef.length;
        dysymtab.iUndefSym = cast(uint)(locals.length + extDef.length);
        dysymtab.nUndefSym = cast(uint)undef.length;
        writeStruct(result, headerSize + segCmdSize + symtabCmdSize, dysymtab);

        // 7. Section data
        if (textSize > 0)
            result[textOffset .. textOffset + textSize] = textCode[];
        if (dataConstSize > 0)
            result[dataConstOffset .. dataConstOffset + dataConstSize] = dataConst[];

        // 8. Relocations
        foreach (i, ref rel; relocEntries) {
            uint off = relocStart + cast(uint)(i * RelocationInfo.sizeof);
            writeStruct(result, off, rel);
        }

        // 9. Symbol table (nlist_64 entries)
        foreach (i, ref s; sortedSymbols) {
            Nlist64 nlist;
            nlist.strIndex = stringOffsets[s.name];
            nlist.type = (s.sectionIndex != 0) ? N_SECT : N_UNDF;
            if (s.isExternal) nlist.type |= N_EXT;
            nlist.sect = s.sectionIndex;
            nlist.value = s.value;
            uint off = symtabOffset + cast(uint)(i * Nlist64.sizeof);
            writeStruct(result, off, nlist);
        }

        // 10. String table
        result[strtabOffset .. strtabOffset + strtabSize] = stringTable[];

        return result;
    }

private:
    /// Add a string to the string table, return its offset
    uint addString(string s) {
        if (auto p = s in stringOffsets)
            return *p;
        uint off = cast(uint)stringTable.length;
        stringOffsets[s] = off;
        // Mach-O symbols use _ prefix
        stringTable ~= cast(ubyte)'_';
        stringTable ~= cast(const(ubyte)[])s;
        stringTable ~= 0; // null terminator
        return off;
    }

    static void setName(ref char[16] dst, string name) {
        dst[] = 0;
        foreach (i, c; name) {
            if (i >= 16) break;
            dst[i] = c;
        }
    }

    static void writeStruct(T)(ubyte[] buf, uint offset, ref const T val) {
        auto bytes = (cast(const(ubyte)*)&val)[0 .. T.sizeof];
        buf[offset .. offset + T.sizeof] = bytes[];
    }
}
