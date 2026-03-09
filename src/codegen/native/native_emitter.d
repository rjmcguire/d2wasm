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

class NativeModuleEmitter {
    private SymbolTable symbolTable;

    this(SymbolTable st) {
        this.symbolTable = st;
        // Native backend uses 8-byte pointers (ARM64)
        sliceInfo = SliceInfo(8);
    }

    /// Compile declarations to a Mach-O .o file.
    /// Returns the .o bytes ready to write to disk.
    ubyte[] emit(Declaration[] decls) {
        // Collect functions (skip templates, forward decls)
        FunctionDecl[] funcs;
        FunctionDecl mainFunc;

        foreach (decl; decls) {
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
        auto compiled = new NativeCompiledFunction(funcs, symbolTable, true /* objectMode */);

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

        ubyte[] wrapper = emitMainWrapper(code.length, mainOffset);

        // Combine: user functions + _main wrapper
        ubyte[] fullCode = code ~ wrapper;
        size_t wrapperOffset = code.length;

        // Build Mach-O .o
        auto writer = new MachOWriter();
        writer.setTextSection(fullCode);

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

    /// Emit a minimal C ABI _main wrapper:
    ///   STP x29, x30, [SP, #-16]!
    ///   MOV x29, SP
    ///   BL  <user_main>
    ///   LDP x29, x30, [SP], #16
    ///   RET
    static ubyte[] emitMainWrapper(size_t codeSize, size_t mainFuncOffset) {
        ubyte[] buf = new ubyte[20]; // 5 instructions × 4 bytes
        uint* instrs = cast(uint*)buf.ptr;

        // STP x29, x30, [SP, #-16]!
        instrs[0] = 0xA9BF7BFD;

        // MOV x29, SP  (ADD x29, SP, #0)
        instrs[1] = 0x910003FD;

        // BL <mainFuncOffset>  — relative offset from wrapper instruction to main
        // The wrapper is at codeSize, the BL is at codeSize + 8
        // Target is at mainFuncOffset
        // Relative offset in bytes = mainFuncOffset - (codeSize + 8)
        long relOffset = cast(long)mainFuncOffset - cast(long)(codeSize + 8);
        int imm26 = cast(int)(relOffset / 4);
        instrs[2] = 0x94000000 | (imm26 & 0x03FFFFFF);

        // LDP x29, x30, [SP], #16
        instrs[3] = 0xA8C17BFD;

        // RET
        instrs[4] = 0xD65F03C0;

        return buf;
    }
}
