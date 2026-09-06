/**
 * ELF64 relocatable object writer (x86-64)
 *
 * Produces ET_REL .o files: .text, optional .rodata/.data, relocations,
 * symbol table. RelocType values from the ARM64 Mach-O path are mapped
 * onto x86-64 ELF relocs (lea/call displacements, 64-bit data pointers).
 */
module codegen.native.elf_writer;

import codegen.native.macho_writer : RelocType;

enum : ubyte {
    EI_MAG0 = 0x7F,
    ELFCLASS64 = 2,
    ELFDATA2LSB = 1,
    EV_CURRENT = 1,
    ELFOSABI_SYSV = 0,
}

enum : ushort {
    ET_REL = 1,
    EM_X86_64 = 62,
}

enum : uint {
    SHT_NULL = 0,
    SHT_PROGBITS = 1,
    SHT_SYMTAB = 2,
    SHT_STRTAB = 3,
    SHT_RELA = 4,
}

enum : ulong {
    SHF_WRITE = 0x1,
    SHF_ALLOC = 0x2,
    SHF_EXECINSTR = 0x4,
    SHF_INFO_LINK = 0x40,
}

enum : ubyte {
    STB_LOCAL = 0,
    STB_GLOBAL = 1,
    STT_NOTYPE = 0,
    STT_OBJECT = 1,
    STT_FUNC = 2,
    STT_SECTION = 3,
}

enum : uint {
    R_X86_64_64 = 1,
    R_X86_64_PC32 = 2,
    R_X86_64_PLT32 = 4,
}

enum ushort SHN_UNDEF = 0;

align(1) struct Elf64_Ehdr {
    ubyte[16] e_ident;
    ushort e_type;
    ushort e_machine;
    uint e_version;
    ulong e_entry;
    ulong e_phoff;
    ulong e_shoff;
    uint e_flags;
    ushort e_ehsize;
    ushort e_phentsize;
    ushort e_phnum;
    ushort e_shentsize;
    ushort e_shnum;
    ushort e_shstrndx;
}
static assert(Elf64_Ehdr.sizeof == 64);

align(1) struct Elf64_Shdr {
    uint sh_name;
    uint sh_type;
    ulong sh_flags;
    ulong sh_addr;
    ulong sh_offset;
    ulong sh_size;
    uint sh_link;
    uint sh_info;
    ulong sh_addralign;
    ulong sh_entsize;
}
static assert(Elf64_Shdr.sizeof == 64);

align(1) struct Elf64_Sym {
    uint st_name;
    ubyte st_info;
    ubyte st_other;
    ushort st_shndx;
    ulong st_value;
    ulong st_size;
}
static assert(Elf64_Sym.sizeof == 24);

align(1) struct Elf64_Rela {
    ulong r_offset;
    ulong r_info;
    long r_addend;
}
static assert(Elf64_Rela.sizeof == 24);

private struct SymbolEntry {
    string name;
    ubyte sectionIndex; // 1=.text, 2=.rodata, 3=.data, 0=UNDEF
    ulong value;
    bool isExternal;
}

private struct PendingReloc {
    uint sectionIndex; // 0=text, 1=data (writable)
    uint offset;
    string symbol;
    RelocType type;
}

class ElfWriter {
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
            return; // x86 lea is a single PC32; the ARM page-offset companion is a nop
        relocs ~= PendingReloc(sectionIndex, offset, symbol, type);
    }

    ubyte[] finalize() {
        // Section order:
        // 0 NULL
        // 1 .text
        // 2 .rodata (optional)
        // 3 .data (optional) — index depends on whether .rodata exists
        // then .rela.text, .rela.data (optional)
        // .note.GNU-stack
        // .symtab .strtab .shstrtab

        bool hasRodata = dataConst.length > 0;
        bool hasData = dataData.length > 0;

        SymbolEntry[] locals, globals;
        foreach (ref s; symbols) {
            if (s.isExternal)
                globals ~= s;
            else
                locals ~= s;
        }
        // Locals first, then globals (defined + UNDEF mixed is OK; UNDEF are global)
        auto ordered = locals ~ globals;

        // String tables
        ubyte[] strtab = [0];
        uint[string] strOff;
        uint addStr(ref ubyte[] tab, ref uint[string] map, string s) {
            if (auto p = s in map)
                return *p;
            uint off = cast(uint)tab.length;
            map[s] = off;
            tab ~= cast(const(ubyte)[])s;
            tab ~= 0;
            return off;
        }
        uint[string] shstrMap;
        ubyte[] shstrtab = [0];

        foreach (ref s; ordered)
            addStr(strtab, strOff, s.name);

        // Build ELF symbols (NULL + section symbols + named)
        Elf64_Sym[] elfSyms;
        elfSyms ~= Elf64_Sym.init; // index 0

        // We'll assign shndx after we know section numbers:
        // .text = 1
        ushort textNdx = 1;
        ushort rodataNdx = hasRodata ? 2 : 0;
        ushort dataNdx = 0;
        if (hasData)
            dataNdx = hasRodata ? 3 : 2;

        uint[string] symIndex; // name → elfSyms index

        foreach (ref s; ordered) {
            Elf64_Sym es;
            es.st_name = strOff[s.name];
            ubyte bind = s.isExternal ? STB_GLOBAL : STB_LOCAL;
            ubyte typ = STT_NOTYPE;
            if (s.sectionIndex == 1)
                typ = STT_FUNC;
            else if (s.sectionIndex != 0)
                typ = STT_OBJECT;
            es.st_info = cast(ubyte)((bind << 4) | typ);
            if (s.sectionIndex == 0)
                es.st_shndx = SHN_UNDEF;
            else if (s.sectionIndex == 1)
                es.st_shndx = textNdx;
            else if (s.sectionIndex == 2)
                es.st_shndx = rodataNdx ? rodataNdx : dataNdx;
            else
                es.st_shndx = dataNdx;
            es.st_value = s.value;
            elfSyms ~= es;
            symIndex[s.name] = cast(uint)(elfSyms.length - 1);
        }

        uint firstGlobal = 1 + cast(uint)locals.length; // after NULL + locals

        // Relocations
        Elf64_Rela[] textRelas;
        Elf64_Rela[] dataRelas;
        foreach (ref r; relocs) {
            uint si = symIndex.get(r.symbol, 0);
            Elf64_Rela rela;
            uint rtype;
            final switch (r.type) {
                case RelocType.branch26:
                    // call rel32: reloc on disp32 (offset+1), addend -4
                    rela.r_offset = r.offset + 1;
                    rtype = R_X86_64_PLT32;
                    rela.r_addend = -4;
                    break;
                case RelocType.page21:
                    // lea rax, [rip+disp32]: disp at +3, addend -4
                    rela.r_offset = r.offset + 3;
                    rtype = R_X86_64_PC32;
                    rela.r_addend = -4;
                    break;
                case RelocType.pageoff12:
                    continue;
                case RelocType.unsigned64:
                    rela.r_offset = r.offset;
                    rtype = R_X86_64_64;
                    rela.r_addend = 0;
                    break;
            }
            rela.r_info = (cast(ulong)si << 32) | rtype;
            if (r.sectionIndex == 1)
                dataRelas ~= rela;
            else
                textRelas ~= rela;
        }

        bool hasTextRela = textRelas.length > 0;
        bool hasDataRela = dataRelas.length > 0;

        // Assign remaining section indices
        ushort ndx = 1;
        ndx++; // .text = 1, next
        if (hasRodata) ndx++;
        if (hasData) ndx++;
        ushort relaTextNdx = 0, relaDataNdx = 0;
        if (hasTextRela) relaTextNdx = ndx++;
        if (hasDataRela) relaDataNdx = ndx++;
        ushort noteNdx = ndx++;
        ushort symtabNdx = ndx++;
        ushort strtabNdx = ndx++;
        ushort shstrNdx = ndx++;
        ushort nSections = ndx; // including NULL at 0

        uint shstr(string name) { return addStr(shstrtab, shstrMap, name); }
        uint nameText = shstr(".text");
        uint nameRodata = hasRodata ? shstr(".rodata") : 0;
        uint nameData = hasData ? shstr(".data") : 0;
        uint nameRelaText = hasTextRela ? shstr(".rela.text") : 0;
        uint nameRelaData = hasDataRela ? shstr(".rela.data") : 0;
        uint nameNote = shstr(".note.GNU-stack");
        uint nameSymtab = shstr(".symtab");
        uint nameStrtab = shstr(".strtab");
        uint nameShstr = shstr(".shstrtab");

        // Layout contents after ELF header
        uint pos = Elf64_Ehdr.sizeof;

        uint alignTo(uint p, uint a) {
            return (p + a - 1) & ~(a - 1);
        }

        pos = alignTo(pos, 16);
        uint textOff = pos;
        uint textSize = cast(uint)textCode.length;
        pos += textSize;

        uint rodataOff = 0, rodataSize = 0;
        if (hasRodata) {
            pos = alignTo(pos, 8);
            rodataOff = pos;
            rodataSize = cast(uint)dataConst.length;
            pos += rodataSize;
        }

        uint dataOff = 0, dataSize = 0;
        if (hasData) {
            pos = alignTo(pos, 8);
            dataOff = pos;
            dataSize = cast(uint)dataData.length;
            pos += dataSize;
        }

        uint relaTextOff = 0, relaTextSize = 0;
        if (hasTextRela) {
            pos = alignTo(pos, 8);
            relaTextOff = pos;
            relaTextSize = cast(uint)(textRelas.length * Elf64_Rela.sizeof);
            pos += relaTextSize;
        }

        uint relaDataOff = 0, relaDataSize = 0;
        if (hasDataRela) {
            pos = alignTo(pos, 8);
            relaDataOff = pos;
            relaDataSize = cast(uint)(dataRelas.length * Elf64_Rela.sizeof);
            pos += relaDataSize;
        }

        // .note.GNU-stack: empty
        uint noteOff = pos;
        uint noteSize = 0;

        pos = alignTo(pos, 8);
        uint symtabOff = pos;
        uint symtabSize = cast(uint)(elfSyms.length * Elf64_Sym.sizeof);
        pos += symtabSize;

        uint strtabOff = pos;
        uint strtabSize = cast(uint)strtab.length;
        pos += strtabSize;

        uint shstrOff = pos;
        uint shstrSize = cast(uint)shstrtab.length;
        pos += shstrSize;

        pos = alignTo(pos, 8);
        uint shoff = pos;
        uint shdrsSize = nSections * Elf64_Shdr.sizeof;
        uint total = shoff + shdrsSize;

        auto result = new ubyte[total];

        void put(uint off, const(ubyte)[] bytes) {
            if (bytes.length == 0) return;
            result[off .. off + bytes.length] = bytes[];
        }
        void putStruct(T)(uint off, auto ref T val) {
            put(off, (cast(const(ubyte)*)&val)[0 .. T.sizeof]);
        }

        Elf64_Ehdr eh;
        eh.e_ident[0] = EI_MAG0;
        eh.e_ident[1] = 'E';
        eh.e_ident[2] = 'L';
        eh.e_ident[3] = 'F';
        eh.e_ident[4] = ELFCLASS64;
        eh.e_ident[5] = ELFDATA2LSB;
        eh.e_ident[6] = EV_CURRENT;
        eh.e_ident[7] = ELFOSABI_SYSV;
        eh.e_type = ET_REL;
        eh.e_machine = EM_X86_64;
        eh.e_version = EV_CURRENT;
        eh.e_ehsize = Elf64_Ehdr.sizeof;
        eh.e_shentsize = Elf64_Shdr.sizeof;
        eh.e_shnum = nSections;
        eh.e_shoff = shoff;
        eh.e_shstrndx = shstrNdx;
        putStruct(0, eh);

        put(textOff, textCode);
        if (hasRodata) put(rodataOff, dataConst);
        if (hasData) put(dataOff, dataData);
        foreach (i, ref rela; textRelas)
            putStruct(relaTextOff + cast(uint)(i * Elf64_Rela.sizeof), rela);
        foreach (i, ref rela; dataRelas)
            putStruct(relaDataOff + cast(uint)(i * Elf64_Rela.sizeof), rela);
        foreach (i, ref es; elfSyms)
            putStruct(symtabOff + cast(uint)(i * Elf64_Sym.sizeof), es);
        put(strtabOff, strtab);
        put(shstrOff, shstrtab);

        Elf64_Shdr[] shdrs = new Elf64_Shdr[nSections];

        void fill(ushort i, uint name, uint type, ulong flags, uint off, uint size,
                  uint link, uint info, ulong align_, ulong entsize) {
            shdrs[i].sh_name = name;
            shdrs[i].sh_type = type;
            shdrs[i].sh_flags = flags;
            shdrs[i].sh_offset = off;
            shdrs[i].sh_size = size;
            shdrs[i].sh_link = link;
            shdrs[i].sh_info = info;
            shdrs[i].sh_addralign = align_;
            shdrs[i].sh_entsize = entsize;
        }

        fill(textNdx, nameText, SHT_PROGBITS, SHF_ALLOC | SHF_EXECINSTR,
             textOff, textSize, 0, 0, 16, 0);
        if (hasRodata)
            fill(rodataNdx, nameRodata, SHT_PROGBITS, SHF_ALLOC,
                 rodataOff, rodataSize, 0, 0, 8, 0);
        if (hasData)
            fill(dataNdx, nameData, SHT_PROGBITS, SHF_WRITE | SHF_ALLOC,
                 dataOff, dataSize, 0, 0, 8, 0);
        if (hasTextRela)
            fill(relaTextNdx, nameRelaText, SHT_RELA, SHF_INFO_LINK,
                 relaTextOff, relaTextSize, symtabNdx, textNdx, 8, Elf64_Rela.sizeof);
        if (hasDataRela)
            fill(relaDataNdx, nameRelaData, SHT_RELA, SHF_INFO_LINK,
                 relaDataOff, relaDataSize, symtabNdx, dataNdx, 8, Elf64_Rela.sizeof);
        fill(noteNdx, nameNote, SHT_PROGBITS, 0, noteOff, noteSize, 0, 0, 1, 0);
        fill(symtabNdx, nameSymtab, SHT_SYMTAB, 0,
             symtabOff, symtabSize, strtabNdx, firstGlobal, 8, Elf64_Sym.sizeof);
        fill(strtabNdx, nameStrtab, SHT_STRTAB, 0, strtabOff, strtabSize, 0, 0, 1, 0);
        fill(shstrNdx, nameShstr, SHT_STRTAB, 0, shstrOff, shstrSize, 0, 0, 1, 0);

        foreach (i, ref sh; shdrs)
            putStruct(shoff + cast(uint)(i * Elf64_Shdr.sizeof), sh);

        return result;
    }
}
