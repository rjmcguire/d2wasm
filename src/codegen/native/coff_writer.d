/**
 * COFF/x86-64 relocatable object writer.
 *
 * Same public surface as ElfWriter. RelocType values from the Mach-O path
 * map onto IMAGE_REL_AMD64_REL32 (call and rip-relative lea) and
 * IMAGE_REL_AMD64_ADDR64 (absolute data pointers).
 */
module codegen.native.coff_writer;

import codegen.native.macho_writer : RelocType;

enum ushort IMAGE_FILE_MACHINE_AMD64 = 0x8664;

enum uint IMAGE_SCN_CNT_CODE = 0x00000020;
enum uint IMAGE_SCN_CNT_INITIALIZED_DATA = 0x00000040;
enum uint IMAGE_SCN_MEM_EXECUTE = 0x20000000;
enum uint IMAGE_SCN_MEM_READ = 0x40000000;
enum uint IMAGE_SCN_MEM_WRITE = 0x80000000;

enum ushort IMAGE_REL_AMD64_ADDR64 = 0x0001;
enum ushort IMAGE_REL_AMD64_REL32 = 0x0004;

enum ubyte IMAGE_SYM_CLASS_EXTERNAL = 2;
enum ubyte IMAGE_SYM_CLASS_STATIC = 3;
enum ushort IMAGE_SYM_DTYPE_FUNCTION = 2;

align(1) struct CoffFileHeader {
    ushort machine;
    ushort numberOfSections;
    uint timeDateStamp;
    uint pointerToSymbolTable;
    uint numberOfSymbols;
    ushort sizeOfOptionalHeader;
    ushort characteristics;
}
static assert(CoffFileHeader.sizeof == 20);

align(1) struct CoffSectionHeader {
    ubyte[8] name;
    uint virtualSize;
    uint virtualAddress;
    uint sizeOfRawData;
    uint pointerToRawData;
    uint pointerToRelocations;
    uint pointerToLinenumbers;
    ushort numberOfRelocations;
    ushort numberOfLinenumbers;
    uint characteristics;
}
static assert(CoffSectionHeader.sizeof == 40);

align(1) struct CoffReloc {
    uint virtualAddress;
    uint symbolTableIndex;
    ushort type;
}
static assert(CoffReloc.sizeof == 10);

align(1) struct CoffSymbol {
    ubyte[8] name;
    uint value;
    short sectionNumber;
    ushort type;
    ubyte storageClass;
    ubyte numberOfAuxSymbols;
}
static assert(CoffSymbol.sizeof == 18);

private struct SymbolEntry {
    string name;
    ubyte sectionIndex; // 1=.text, 2=.rdata or .data, 3=.data, 0=UNDEF
    ulong value;
    bool isExternal;
}

private struct PendingReloc {
    uint sectionIndex; // 0=text, 1=writable data
    uint offset;
    string symbol;
    RelocType type;
}

class CoffWriter {
    private const(ubyte)[] textCode;
    private const(ubyte)[] dataConst;
    private const(ubyte)[] dataData;
    private SymbolEntry[] symbols;
    private PendingReloc[] relocs;

    void setTextSection(const(ubyte)[] code) { textCode = code; }
    void setDataConstSection(const(ubyte)[] data) { dataConst = data; }
    void setDataSection(const(ubyte)[] data) { dataData = data; }

    void addExportedSymbol(string name, ubyte sectionIndex, ulong offset) {
        symbols ~= SymbolEntry(name, sectionIndex, offset, true);
    }
    void addLocalSymbol(string name, ubyte sectionIndex, ulong offset) {
        symbols ~= SymbolEntry(name, sectionIndex, offset, false);
    }
    void addExternalSymbol(string name) {
        symbols ~= SymbolEntry(name, 0, 0, true);
    }
    void addRelocation(uint sectionIndex, uint offset, string symbol, RelocType type) {
        if (type == RelocType.pageoff12)
            return;
        relocs ~= PendingReloc(sectionIndex, offset, symbol, type);
    }

    ubyte[] finalize() {
        bool hasRodata = dataConst.length > 0;
        bool hasData = dataData.length > 0;

        ushort textNdx = 1;
        ushort rodataNdx = hasRodata ? 2 : 0;
        ushort dataNdx = 0;
        if (hasData)
            dataNdx = hasRodata ? 3 : 2;

        // section index used by the emitter → COFF section number
        short coffSection(ubyte sectionIndex) {
            if (sectionIndex == 0)
                return 0;
            if (sectionIndex == 1)
                return textNdx;
            if (sectionIndex == 2)
                return cast(short)(rodataNdx ? rodataNdx : dataNdx);
            return dataNdx;
        }

        ubyte[] strtab = [0, 0, 0, 0]; // length filled in at the end
        uint[string] strOff;

        CoffSymbol makeSymbol(ref SymbolEntry s) {
            CoffSymbol sym;
            if (s.name.length <= 8) {
                sym.name[0 .. s.name.length] = cast(ubyte[])s.name;
            } else {
                uint off = cast(uint)strtab.length;
                strOff[s.name] = off;
                strtab ~= cast(ubyte[])s.name;
                strtab ~= 0;
                sym.name[4] = cast(ubyte)(off);
                sym.name[5] = cast(ubyte)(off >> 8);
                sym.name[6] = cast(ubyte)(off >> 16);
                sym.name[7] = cast(ubyte)(off >> 24);
            }
            sym.value = cast(uint)s.value;
            sym.sectionNumber = coffSection(s.sectionIndex);
            if (s.sectionIndex == 1)
                sym.type = cast(ushort)(IMAGE_SYM_DTYPE_FUNCTION << 4);
            sym.storageClass = (s.isExternal || s.sectionIndex == 0)
                ? IMAGE_SYM_CLASS_EXTERNAL
                : IMAGE_SYM_CLASS_STATIC;
            return sym;
        }

        CoffSymbol[] coffSyms;
        uint[string] symIndex;
        foreach (ref s; symbols) {
            symIndex[s.name] = cast(uint)coffSyms.length;
            coffSyms ~= makeSymbol(s);
        }

        CoffReloc[] textRelas;
        CoffReloc[] dataRelas;
        foreach (ref r; relocs) {
            uint si = symIndex.get(r.symbol, 0);
            CoffReloc rel;
            rel.symbolTableIndex = si;
            final switch (r.type) {
                case RelocType.branch26:
                    rel.virtualAddress = r.offset + 1;
                    rel.type = IMAGE_REL_AMD64_REL32;
                    break;
                case RelocType.page21:
                    rel.virtualAddress = r.offset + 3;
                    rel.type = IMAGE_REL_AMD64_REL32;
                    break;
                case RelocType.pageoff12:
                    continue;
                case RelocType.unsigned64:
                    rel.virtualAddress = r.offset;
                    rel.type = IMAGE_REL_AMD64_ADDR64;
                    break;
            }
            if (r.sectionIndex == 1)
                dataRelas ~= rel;
            else
                textRelas ~= rel;
        }

        static uint alignTo(uint p, uint a) {
            return (p + a - 1) & ~(a - 1);
        }

        ushort nSections = 1;
        if (hasRodata) nSections++;
        if (hasData) nSections++;

        uint pos = CoffFileHeader.sizeof + nSections * CoffSectionHeader.sizeof;

        pos = alignTo(pos, 4);
        uint textOff = pos;
        uint textSize = cast(uint)textCode.length;
        pos += textSize;

        uint textRelOff = 0;
        if (textRelas.length > 0) {
            pos = alignTo(pos, 4);
            textRelOff = pos;
            pos += cast(uint)(textRelas.length * CoffReloc.sizeof);
        }

        uint rodataOff = 0, rodataSize = 0;
        if (hasRodata) {
            pos = alignTo(pos, 4);
            rodataOff = pos;
            rodataSize = cast(uint)dataConst.length;
            pos += rodataSize;
        }

        uint dataOff = 0, dataSize = 0, dataRelOff = 0;
        if (hasData) {
            pos = alignTo(pos, 4);
            dataOff = pos;
            dataSize = cast(uint)dataData.length;
            pos += dataSize;
            if (dataRelas.length > 0) {
                pos = alignTo(pos, 4);
                dataRelOff = pos;
                pos += cast(uint)(dataRelas.length * CoffReloc.sizeof);
            }
        }

        pos = alignTo(pos, 4);
        uint symOff = pos;
        uint symSize = cast(uint)(coffSyms.length * CoffSymbol.sizeof);
        pos += symSize;

        uint strSize = cast(uint)strtab.length;
        if (strSize < 4) strSize = 4;
        *cast(uint*)strtab.ptr = strSize;

        uint total = pos + strSize;
        auto result = new ubyte[total];

        void put(uint off, const(ubyte)[] bytes) {
            if (bytes.length == 0) return;
            result[off .. off + bytes.length] = bytes[];
        }
        void putStruct(T)(uint off, auto ref T val) {
            put(off, (cast(const(ubyte)*)&val)[0 .. T.sizeof]);
        }

        CoffFileHeader fh;
        fh.machine = IMAGE_FILE_MACHINE_AMD64;
        fh.numberOfSections = nSections;
        fh.pointerToSymbolTable = symOff;
        fh.numberOfSymbols = cast(uint)coffSyms.length;
        putStruct(0, fh);

        uint hdrAt = CoffFileHeader.sizeof;
        void putSection(string name, uint rawSize, uint rawOff, uint relOff, ushort nrel, uint flags) {
            CoffSectionHeader sh;
            auto n = name.length > 8 ? 8 : name.length;
            sh.name[0 .. n] = cast(ubyte[])name[0 .. n];
            sh.sizeOfRawData = rawSize;
            sh.pointerToRawData = rawSize ? rawOff : 0;
            sh.pointerToRelocations = nrel ? relOff : 0;
            sh.numberOfRelocations = nrel;
            sh.characteristics = flags;
            putStruct(hdrAt, sh);
            hdrAt += CoffSectionHeader.sizeof;
        }

        putSection(".text", textSize, textOff, textRelOff, cast(ushort)textRelas.length,
            IMAGE_SCN_CNT_CODE | IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_MEM_READ);
        if (hasRodata)
            putSection(".rdata", rodataSize, rodataOff, 0, 0,
                IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ);
        if (hasData)
            putSection(".data", dataSize, dataOff, dataRelOff, cast(ushort)dataRelas.length,
                IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE);

        put(textOff, textCode);
        foreach (i, ref rel; textRelas)
            putStruct(textRelOff + cast(uint)(i * CoffReloc.sizeof), rel);
        if (hasRodata)
            put(rodataOff, dataConst);
        if (hasData)
            put(dataOff, dataData);
        foreach (i, ref rel; dataRelas)
            putStruct(dataRelOff + cast(uint)(i * CoffReloc.sizeof), rel);
        foreach (i, ref sym; coffSyms)
            putStruct(symOff + cast(uint)(i * CoffSymbol.sizeof), sym);
        put(symOff + symSize, strtab);

        return result;
    }
}
