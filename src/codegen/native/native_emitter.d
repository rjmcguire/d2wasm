/**
 * Native Module Emitter
 *
 * Compiles D programs to ARM64 Mach-O .o object files.
 * Mirrors BinaryEmitter's role but targets native ARM64 instead of WASM.
 */
module codegen.native.native_emitter;

import codegen.native.macho_writer;
import codegen.native.backend : NativeCompiledFunction;
import codegen.target : sliceInfo, SliceInfo;
import codegen.mangle : computeMangledName;
import ast.nodes;
import semantic.symbol_table;
import semantic.modules_context : ModulesContext;

class NativeModuleEmitter {
    private SymbolTable symbolTable;

    this(SymbolTable st) {
        this.symbolTable = st;
        // Native backend uses 8-byte pointers (ARM64)
        sliceInfo = SliceInfo(8);
    }

    /// Compile all modules to a Mach-O .o file.
    ubyte[] emit(ModulesContext modulesCtx) {
        Declaration[] allDecls;
        foreach (mod; modulesCtx.modulesInOrder())
            allDecls ~= mod.ast;
        return emit(allDecls);
    }

    /// Compile declarations to a Mach-O .o file.
    /// Returns the .o bytes ready to write to disk.
    ubyte[] emit(Declaration[] decls) {
        // Collect functions and extern(C) imports
        FunctionDecl[] funcs;
        FunctionDecl mainFunc;
        ImportedFunctionDecl[] imports;

        foreach (decl; decls) {
            if (auto imp = cast(ImportedFunctionDecl)decl) {
                if (imp.moduleName == "ffi")
                    imports ~= imp;
                continue;
            }
            // Collect methods from struct/class declarations
            if (auto aggDecl = cast(AggregateDecl)decl) {
                if (auto classDecl = cast(ClassDecl)decl) {
                    if (classDecl.isObjC) {
                        // ObjC classes: only collect methods with D bodies
                        foreach (member; classDecl.members) {
                            auto method = cast(FunctionDecl)member;
                            if (method is null) continue;
                            if (method.body_ is null) continue;
                            funcs ~= method;
                        }
                        continue;
                    }
                }
                foreach (member; aggDecl.members) {
                    auto method = cast(FunctionDecl)member;
                    if (method is null) continue;
                    if (method.body_ is null) continue;
                    if (method.isTemplate) continue;
                    funcs ~= method;
                }
                continue;
            }
            auto funcDecl = cast(FunctionDecl)decl;
            if (funcDecl is null) continue;
            if (funcDecl.body_ is null) continue;     // forward declaration
            if (funcDecl.isTemplate) continue;          // template (not instantiation)

            funcs ~= funcDecl;
            if (funcDecl.name == "main")
                mainFunc = funcDecl;
        }

        if (mainFunc is null)
            throw new Exception("No main() function found");

        // Compile all functions in object mode (relocatable buffer, no CTFE infrastructure)
        auto compiled = new NativeCompiledFunction(funcs, symbolTable, true, imports);

        // Look up main's offset using its mangled name (symbol table sets mangledName
        // during type checking, e.g. "main" → "_D4test4mainFZi")
        string mainKey = mangledNameOf(mainFunc);
        size_t mainOffset = compiled.getFunctionOffset(mainKey);
        if (mainOffset == size_t.max)
            throw new Exception("main() function offset not found (key: " ~ mainKey ~ ")");

        // Get the compiled code bytes (returns a .dup copy)
        ubyte[] code = compiled.getRelocatableCode();
        if (code is null)
            throw new Exception("Failed to finalize native code");

        ubyte[] wrapper = emitMainWrapper(code.length, mainOffset, mainFunc.needsArena);

        // Combine: user functions + _main wrapper
        ubyte[] fullCode = code ~ wrapper;
        size_t wrapperOffset = code.length;

        // Build Mach-O .o
        auto writer = new MachOWriter();
        writer.setTextSection(fullCode);

        // Data section (error messages, constant data → __DATA,__const)
        auto objData = compiled.getObjectData();
        bool hasDataSection = objData.length > 0;
        if (hasDataSection)
            writer.setDataConstSection(objData);

        // External undefined symbols (write, _exit, etc. — resolved by linker)
        foreach (sym; compiled.getObjectExternalSymbols())
            writer.addExternalSymbol(sym);

        // Data symbols (local symbols in __DATA,__const = section 2)
        // Symbol value = virtual address = dataSectionBase + offset within data section.
        // In MH_OBJECT, __DATA,__const vmAddr = textSizePadded (8-byte aligned, follows __text).
        if (hasDataSection) {
            ulong dataVmBase = (fullCode.length + 7) & ~7;  // match MachOWriter padding
            foreach (ds; compiled.getObjectDataSymbols())
                writer.addLocalSymbol(ds.name, 2, dataVmBase + ds.offset);
        }

        // Relocations (ADRP/ADD for data refs, BL for external calls, unsigned64 for vtable)
        foreach (r; compiled.getObjectRelocations())
            writer.addRelocation(r.sectionIndex, r.codeOffset, r.symbol, r.type);

        // Export _main (C entry point).
        // MachOWriter.addString prepends '_', so pass "main" → "_main" in Mach-O.
        writer.addExportedSymbol("main", 1, wrapperOffset);

        // Add user functions as local symbols (for debugging/nm)
        foreach (func; funcs) {
            string key = mangledNameOf(func);
            size_t off = compiled.getFunctionOffset(key);
            if (off != size_t.max)
                writer.addLocalSymbol(key, 1, off);
        }

        compiled.dispose(); // free the malloc'd code buffer

        return writer.finalize();
    }

private:
    /// Get the key used by NativeCompiledFunction.getMangledName for a function.
    /// Mirrors its logic: use mangledName if set, else bare name.
    static string mangledNameOf(FunctionDecl func) {
        if (func.mangledName)
            return func.mangledName;
        if (func.isMethod && func.parent !is null)
            return computeMangledName([], func);
        return func.name;
    }

    /// Emit a C ABI _main wrapper that optionally zeroes x0 for the arena parameter:
    ///   STP x29, x30, [SP, #-16]!
    ///   MOV x29, SP
    ///   [MOV x0, #0]          — only if mainNeedsArena
    ///   BL  <user_main>
    ///   LDP x29, x30, [SP], #16
    ///   RET
    static ubyte[] emitMainWrapper(size_t codeSize, size_t mainFuncOffset, bool mainNeedsArena) {
        uint instrCount = mainNeedsArena ? 6 : 5;
        ubyte[] buf = new ubyte[instrCount * 4];
        uint* instrs = cast(uint*)buf.ptr;

        uint idx = 0;

        // STP x29, x30, [SP, #-16]!
        instrs[idx++] = 0xA9BF7BFD;

        // MOV x29, SP  (ADD x29, SP, #0)
        instrs[idx++] = 0x910003FD;

        // MOV x0, #0  (arena = null) — only if main expects arena parameter
        if (mainNeedsArena)
            instrs[idx++] = 0xD2800000;  // MOVZ x0, #0

        // BL <mainFuncOffset>  — relative offset from this instruction to main
        size_t blOffset = codeSize + idx * 4;
        long relOffset = cast(long)mainFuncOffset - cast(long)blOffset;
        int imm26 = cast(int)(relOffset / 4);
        instrs[idx++] = 0x94000000 | (imm26 & 0x03FFFFFF);

        // LDP x29, x30, [SP], #16
        instrs[idx++] = 0xA8C17BFD;

        // RET
        instrs[idx++] = 0xD65F03C0;

        return buf;
    }
}
