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
import codegen.function_collector;
import codegen.emitter_cache : EmitterCache, EmitterCacheStats;
import cache.entry : CacheEntry, SourceHash;
import ast.nodes;
import semantic.symbol_table;
import semantic.modules_context : ModulesContext;
import semantic.module_ : Module;

class NativeModuleEmitter : EmitterCache {
    private SymbolTable symbolTable;

    // Cache state (mirrors BinaryEmitter's cache interface)
    private string sourceText;
    private ubyte[][string] codeCache;       // mangledName → cached native code bytes
    private SourceHash[string] sourceHashes; // mangledName → source hash
    private bool[string] cacheHits;          // track which functions used cache
    private string[string] funcSourceText;   // mangledName → module source text (for hash computation)

    this(SymbolTable st) {
        this.symbolTable = st;
        // Native backend uses 8-byte pointers (ARM64)
        sliceInfo = SliceInfo(8);
    }

    /// Set source text for hash computation
    void setSourceText(string source) {
        this.sourceText = source;
    }

    /// Pre-populate the code cache with previously compiled function code.
    void setCodeCache(CacheEntry[] entries) {
        foreach (entry; entries) {
            codeCache[entry.memberName] = entry.wasmBytes.dup;
            sourceHashes[entry.memberName] = entry.sourceHash;
        }
    }

    /// Get all emitted function code as cache entries.
    CacheEntry[] getEmittedCode() {
        CacheEntry[] results;
        foreach (name, bytes; codeCache) {
            CacheEntry entry;
            entry.memberName = name;
            entry.sourceHash = (name in sourceHashes) ? sourceHashes[name] : SourceHash.init;
            entry.wasmBytes = bytes;  // field name is "wasmBytes" but works for any bytes
            results ~= entry;
        }
        return results;
    }

    /// Get cache statistics
    EmitterCacheStats getCacheStats() {
        EmitterCacheStats stats;
        stats.totalFunctions = codeCache.length;
        stats.cacheHits = cacheHits.length;
        stats.cacheMisses = stats.totalFunctions - stats.cacheHits;
        return stats;
    }

    /// Evict dirty entries from cache
    void evictFromCache(const(string[]) dirtyNames) {
        foreach (name; dirtyNames) {
            codeCache.remove(name);
            sourceHashes.remove(name);
        }
    }

    /// Compile all modules to a Mach-O .o file.
    /// Processes per-module to preserve module context for source hashing.
    ubyte[] emit(ModulesContext modulesCtx) {
        auto perModule = collectFunctionsPerModule(modulesCtx);

        // Merge all modules into flat lists for the backend,
        // but do per-module cache checking with correct source text
        FunctionDecl[] funcs;
        FunctionDecl mainFunc;
        ImportedFunctionDecl[] imports;
        ClassDecl[] objcClasses;
        ubyte[][string] cachedBytes;

        foreach (ref mf; perModule) {
            imports ~= mf.imports;

            // Use this module's source text for per-function cache checks
            string modSource = mf.mod.sourceText;

            foreach (func; mf.functions) {
                funcs ~= func;
                if (func.name == "main")
                    mainFunc = func;

                // Track per-function source text for cache hash computation
                string name = mangledNameOf(func);
                funcSourceText[name] = modSource;
                if (name in codeCache && modSource.length > 0) {
                    auto loc = func.location;
                    if (loc.endOffset > loc.startOffset && loc.endOffset <= modSource.length) {
                        auto currentHash = CacheEntry.computeHash(
                            modSource[loc.startOffset .. loc.endOffset]);
                        if (name in sourceHashes && sourceHashes[name] == currentHash) {
                            cachedBytes[name] = codeCache[name];
                            cacheHits[name] = true;
                        }
                    }
                }
            }
        }

        // Collect ObjC classes from all modules
        foreach (mod; modulesCtx.modulesInOrder()) {
            auto modCollected = collectFunctions(mod.ast);
            objcClasses ~= modCollected.objcClasses;
        }

        return emitFunctions(funcs, mainFunc, imports, cachedBytes, objcClasses);
    }

    /// Compile declarations to a Mach-O .o file (single-module path).
    /// Returns the .o bytes ready to write to disk.
    ubyte[] emit(Declaration[] decls) {
        auto collected = collectFunctions(decls);

        // Build per-function cache lookup using the emitter's sourceText
        ubyte[][string] cachedBytes;
        if (sourceText.length > 0 && codeCache.length > 0) {
            foreach (func; collected.functions) {
                string name = mangledNameOf(func);
                if (name !in codeCache) continue;
                auto loc = func.location;
                if (loc.endOffset > loc.startOffset && loc.endOffset <= sourceText.length) {
                    auto currentHash = CacheEntry.computeHash(
                        sourceText[loc.startOffset .. loc.endOffset]);
                    if (name in sourceHashes && sourceHashes[name] == currentHash) {
                        cachedBytes[name] = codeCache[name];
                        cacheHits[name] = true;
                    }
                }
            }
        }

        return emitFunctions(collected.functions, collected.mainFunc, collected.imports,
                             cachedBytes, collected.objcClasses);
    }

    /// Core emission: compile functions to Mach-O .o bytes.
    private ubyte[] emitFunctions(FunctionDecl[] funcs, FunctionDecl mainFunc,
                                  ImportedFunctionDecl[] imports, ubyte[][string] cachedBytes,
                                  ClassDecl[] objcClasses = null) {
        if (mainFunc is null)
            throw new Exception("No main() function found");

        // Compile functions in object mode, injecting cached bytes where available
        auto compiled = new NativeCompiledFunction(
            funcs, symbolTable, true, imports, cachedBytes, objcClasses);

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

        // Check for ObjC class init function
        size_t objcInitOffset = compiled.getFunctionOffset("__objc_class_init");
        bool hasObjCInit = objcInitOffset != size_t.max;

        ubyte[] wrapper = emitMainWrapper(code.length, mainOffset, mainFunc.needsArena,
                                          hasObjCInit ? objcInitOffset : size_t.max);

        // Combine: user functions + _main wrapper
        ubyte[] fullCode = code ~ wrapper;
        size_t wrapperOffset = code.length;

        // Build Mach-O .o
        auto writer = new MachOWriter();
        writer.setTextSection(fullCode);

        // Constant data section (error messages, C strings → __DATA,__const)
        auto objData = compiled.getObjectData();
        bool hasConstData = objData.length > 0;
        if (hasConstData)
            writer.setDataConstSection(objData);

        // Writable data section (mutable globals → __DATA,__data)
        auto globData = compiled.getGlobalData();
        bool hasGlobalData = globData.length > 0;
        if (hasGlobalData)
            writer.setDataSection(globData);

        // External undefined symbols (write, _exit, etc. — resolved by linker)
        foreach (sym; compiled.getObjectExternalSymbols())
            writer.addExternalSymbol(sym);

        // Const data symbols (section 2: __DATA,__const)
        ulong dataVmBase = (fullCode.length + 7) & ~7;
        if (hasConstData) {
            foreach (ds; compiled.getObjectDataSymbols())
                writer.addLocalSymbol(ds.name, 2, dataVmBase + ds.offset);
        }

        // Global data symbols (section 2 or 3 depending on whether const data exists)
        if (hasGlobalData) {
            ubyte globalSectIdx = hasConstData ? 3 : 2;
            ulong constSizePadded = hasConstData ? ((objData.length + 7) & ~7) : 0;
            ulong globalVmBase = dataVmBase + constSizePadded;
            foreach (ds; compiled.getGlobalDataSymbols())
                writer.addLocalSymbol(ds.name, globalSectIdx, globalVmBase + ds.offset);
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

        // Add ObjC trampoline and init symbols (needed for ADRP/ADD relocations)
        foreach (name; compiled.getObjCSymbolNames()) {
            size_t off = compiled.getFunctionOffset(name);
            if (off != size_t.max)
                writer.addLocalSymbol(name, 1, off);
        }

        // Capture per-function code into cache for next compilation
        foreach (ref info; compiled.getPerFunctionCode()) {
            auto funcBytes = NativeCompiledFunction.extractFunctionBytes(code, info);
            if (funcBytes !is null) {
                codeCache[info.mangledName] = funcBytes;
                // Compute and store source hash using per-module source text
                foreach (func; funcs) {
                    if (mangledNameOf(func) == info.mangledName) {
                        string src = (info.mangledName in funcSourceText)
                            ? funcSourceText[info.mangledName]
                            : sourceText;
                        auto loc = func.location;
                        if (src.length > 0 && loc.endOffset > loc.startOffset
                            && loc.endOffset <= src.length) {
                            sourceHashes[info.mangledName] = CacheEntry.computeHash(
                                src[loc.startOffset .. loc.endOffset]);
                        }
                        break;
                    }
                }
            }
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
    static ubyte[] emitMainWrapper(size_t codeSize, size_t mainFuncOffset, bool mainNeedsArena,
                                    size_t objcInitOffset = size_t.max) {
        bool hasObjCInit = objcInitOffset != size_t.max;
        uint instrCount = 5 + (mainNeedsArena ? 1 : 0) + (hasObjCInit ? 1 : 0);
        ubyte[] buf = new ubyte[instrCount * 4];
        uint* instrs = cast(uint*)buf.ptr;

        uint idx = 0;

        // STP x29, x30, [SP, #-16]!
        instrs[idx++] = 0xA9BF7BFD;

        // MOV x29, SP  (ADD x29, SP, #0)
        instrs[idx++] = 0x910003FD;

        // BL __objc_class_init (register ObjC classes before main)
        if (hasObjCInit) {
            size_t blOff = codeSize + idx * 4;
            long rel = cast(long)objcInitOffset - cast(long)blOff;
            int imm = cast(int)(rel / 4);
            instrs[idx++] = 0x94000000 | (imm & 0x03FFFFFF);
        }

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
