/**
 * Native Backend Implementation
 * 
 * Implements the Backend interface for native ARM64 target.
 * Uses copy-and-patch code generation for JIT compilation.
 */
module codegen.native.backend;

import codegen.backend : Backend, CompiledFunction, ExecutionResult;
import codegen.target : sliceInfo, SliceInfo;
import codegen.native.arm64_codegen : NativeCodeGen, CallFrameData, ErrorLocData,
    createCTFEHostFunctions;
import codegen.native.macho_writer : RelocType;
import codegen.native.arm64.stencil_table;
import codegen.native.stencil_catalog;
import codegen.native.codegen_interface : Label, NativeDataSection, NativeCTFEContext,
    HostFunctionTable, CTFEErrorKind, ctfeErrorMessage, setjmp;
import ast.nodes;
import ast.statements;
import ast.expressions;
import semantic.symbol_table;
import semantic.type_checker;
import std.conv : to;
import diagnostic.log : log;

alias ArrayType = ast.nodes.ArrayType;

class NativeCompileError : Exception {
    SourceLocation location;
    this(string msg, SourceLocation loc) {
        super(msg);
        this.location = loc;
    }
}

class NativeBackend : Backend {
    private SymbolTable symbolTable;
    private string lastError;
    private SourceLocation lastErrorLoc;
    private bool enableStackTrace;
    
    this(SymbolTable st, bool enableStackTrace = true) {
        this.symbolTable = st;
        this.enableStackTrace = enableStackTrace;
        // Native backend uses 8-byte pointers (ARM64)
        sliceInfo = SliceInfo(8);
    }
    
    override CompiledFunction compile(FunctionDecl func) {
        // Type-check first
        auto typeChecker = new TypeChecker(symbolTable);
        try {
            typeChecker.checkFunctionDeclaration(func);
        } catch (Exception e) {
            lastError = "Type check error: " ~ e.msg;
            return null;
        }
        
        try {
            return new NativeCompiledFunction(func, symbolTable, enableStackTrace);
        } catch (NativeCompileError e) {
            lastError = "Native compile error: " ~ e.msg;
            lastErrorLoc = e.location;
            return null;
        } catch (Exception e) {
            lastError = "Native compile error: " ~ e.msg;
            lastErrorLoc = SourceLocation.init;
            return null;
        }
    }

    override CompiledFunction compileWithDependencies(FunctionDecl[] funcs, string entryFuncName,
            ImportedFunctionDecl[] imports = null) {
        // Type-check all functions first
        auto typeChecker = new TypeChecker(symbolTable);
        foreach (func; funcs) {
            try {
                typeChecker.checkFunctionDeclaration(func);
            } catch (Exception e) {
                lastError = "Type check error in " ~ func.name ~ ": " ~ e.msg;
                return null;
            }
        }

        try {
            return new NativeCompiledFunction(funcs, entryFuncName, symbolTable, enableStackTrace, imports);
        } catch (NativeCompileError e) {
            lastError = "Native compile error: " ~ e.msg;
            lastErrorLoc = e.location;
            return null;
        } catch (Exception e) {
            lastError = "Native compile error: " ~ e.msg;
            lastErrorLoc = SourceLocation.init;
            return null;
        }
    }
    
    override ubyte[] compileModule(Declaration[] decls) {
        // Native backend doesn't produce portable binary output (yet)
        // For now, only supports single-function CTFE compilation
        lastError = "Native backend does not support module compilation";
        return null;
    }
    
    override string error() { return lastError; }
    override SourceLocation errorLocation() { return lastErrorLoc; }
    override string name() { return "native"; }
}

/// Compute element size for a type in native target context.
/// Dynamic array elements are slice structs (sliceInfo.totalSize).
private uint nativeElementSize(Type elemType) {
    if (auto at = cast(ArrayType)elemType)
        if (!at.isStaticArray) return sliceInfo.totalSize;
    auto s = elemType.size();
    return s == 0 ? 4 : cast(uint)s;
}

/**
 * Native compiled function - executes ARM64 code directly
 */
class NativeCompiledFunction : CompiledFunction {
    // Additional imports for this class
    import semantic.symbol_table : SymbolKind;
    
    private string funcName;
    private NativeCodeGen gen;  // renamed from codegen to avoid module name collision
    private size_t entryPoint;
    private size_t paramCount;           // number of function parameters
    private bool entryNeedsArena;        // whether the entry function has needsArena
    private SymbolTable symbolTable;     // for looking up struct types
    
    /// Discriminant for variable types — used with `final switch` for exhaustive dispatch.
    enum VarKind {
        scalar,
        struct_,
        class_,
        slice,
        staticArray,
        delegate_,
    }

    // Unified local variable info
    struct NativeLocalInfo {
        VarKind kind;
        size_t offset;            // Stack offset (size_t for 64-bit targets)
        StructDecl structDecl;    // Non-null when kind == struct_
        ClassDecl classDecl;      // Non-null when kind == class_
        InterfaceDecl interfaceDecl; // Non-null for ObjC interface-typed variables
        Type elementType;         // Element type for staticArray/slice
        uint staticArraySize;     // Element count when kind == staticArray
        uint staticArrayElemSize; // Element byte size when kind == staticArray
        uint sliceElemSize;       // Element byte size when kind == slice
        bool isReference;         // true for 'this' pointers (stores address, not inline data)
        bool isObjCRef;           // true for ObjC opaque pointers (8-byte, no vtable)
        bool isRawPointer;        // true for raw pointer types (char*, int*, etc.) — 8 bytes on ARM64

        bool isStruct() const { return kind == VarKind.struct_; }
        bool isClass() const { return kind == VarKind.class_; }
        bool isSlice() const { return kind == VarKind.slice; }
        bool isStaticArray() const { return kind == VarKind.staticArray; }

        /// Get element size for any array-like kind
        uint elemSize() const {
            if (kind == VarKind.staticArray) return staticArrayElemSize;
            if (kind == VarKind.slice) return sliceElemSize;
            return 4;
        }
    }
    /// Stack-style temporary offset allocator for expression evaluation scratch space.
    /// All allocations are 8-byte aligned. Supports save/restore for LIFO batch deallocation.
    private struct TempAllocator {
        private size_t base;      // absolute stack offset where temp zone starts
        private size_t watermark; // current allocation point (bytes from base)
        private size_t capacity;  // total bytes available

        alias Mark = size_t;

        void initialize(size_t baseOffset, size_t cap) {
            base = baseOffset;
            watermark = 0;
            capacity = cap;
        }

        /// Allocate `nbytes` of scratch space (8-byte aligned). Returns absolute stack offset.
        size_t alloc(size_t nbytes) {
            import std.conv : to;
            size_t aligned = (watermark + 7) & ~cast(size_t)7;
            size_t allocSize = (nbytes + 7) & ~cast(size_t)7;
            assert(aligned + allocSize <= capacity,
                "TempAllocator overflow: need " ~ (aligned + allocSize).to!string ~
                " bytes, capacity " ~ capacity.to!string);
            watermark = aligned + allocSize;
            return base + aligned;
        }

        /// Save current watermark for later restore.
        Mark save() { return watermark; }

        /// Restore watermark to a previously saved position.
        void restore(Mark m) {
            assert(m <= watermark, "TempAllocator: restoring to future position");
            watermark = m;
        }

        /// Base offset of the temp zone (for frame overflow asserts).
        size_t tempBase() const { return base; }
    }

    private NativeLocalInfo[string] localVars;
    private size_t nextLocalOffset;
    private size_t totalLocalBytes;
    private TempAllocator temps;

    // Large return tracking (hidden result pointer pattern)
    private bool currentFunctionHasHiddenResult;
    private size_t currentFunctionResultPtrOffset;
    private StructDecl currentFunctionReturnStructDecl;
    private size_t currentFunctionReturnArrayBytes;  // >0 for static array returns

    // Method tracking (hidden 'this' parameter)
    private StructDecl currentMethodStruct;  // non-null when compiling a struct method
    private ClassDecl currentMethodClass;    // non-null when compiling a class method
    private size_t currentThisOffset;        // stack offset of 'this' pointer

    /// Returns the current method's parent aggregate (struct or class), or null.
    private AggregateDecl currentMethodAggregate() {
        if (currentMethodStruct) return cast(AggregateDecl)currentMethodStruct;
        if (currentMethodClass) return cast(AggregateDecl)currentMethodClass;
        return null;
    }

    // ObjC interface/class tracking
    private InterfaceDecl[string] objcInterfaces;
    private ClassDecl[string] objcClasses;

    // Vtable infrastructure for class virtual dispatch
    private uint nextNativeTableBase = 0;       // sequential counter for vtable base indices
    private size_t vtableStartOffset = size_t.max; // data section offset where vtable array starts
    private uint[string] classTableBases;       // className → nativeTableBase
    private string[] vtableMethodNames;          // flat: vtableMethodNames[tableBase + slot] = mangledName

    // Arena tracking (hidden __arena parameter)
    private bool currentFunctionHasArena;
    private size_t currentFunctionArenaOffset;

    // For return statements to jump to
    private Label epilogueLabel;

    // Loop stack for break/continue
    private struct NativeLoopContext {
        Label breakLabel;
        Label continueLabel;
    }
    private NativeLoopContext[] nativeLoopStack;

    // Exception handling (try/catch/throw) — global-flag mechanism
    private struct NativeTryContext {
        Label catchLabel;       // branch here when exception detected
        Label afterLabel;       // branch here after normal try body (skip catch)
    }
    private NativeTryContext[] tryStack;
    private ubyte* exceptionPendingAddr;  // absolute address in data section (i32)
    private ubyte* exceptionDepthAddr;    // absolute address in data section (i32)
    private ubyte* exceptionSlotsAddr;    // absolute address of exception slot array (100 * 24 bytes)

    // For multi-function support: map function names to their labels
    private Label[string] functionLabels;
    private FunctionDecl[string] functionDecls;  // for looking up parameter counts
    
    // Data section for external data (import() file contents, etc.) - Milestone 85/86
    private NativeDataSection dataSection;
    
    // Host function table for CTFE intrinsics - Milestone 87/88
    private HostFunctionTable hostFunctions;

    // FFI function pointer slots (extern(C) imports resolved via dlsym)
    private ulong[string] ffiSlots;
    
    // Stack trace option
    private bool enableStackTrace;

    // Object file mode: skip CTFE-only infrastructure (exceptions, host functions, data section)
    private bool objectMode;

    // Object-mode data section (error strings, constant data → __DATA,__const in .o)
    private ubyte[] objectData;

    static struct ObjectDataSymbol { string name; uint offset; }
    private ObjectDataSymbol[] objectDataSymbols;

    static struct ObjectReloc { uint codeOffset; string symbol; RelocType type; uint sectionIndex = 0; }
    private ObjectReloc[] objectRelocations;

    private string[] objectExternalSymbols;
    private uint objectDataSymCount;
    private bool[string] objectExternFunctions;  // extern(C) function names for object mode

    /// Single function constructor (original)
    this(FunctionDecl func, SymbolTable st, bool enableStackTrace = true) {
        import std.stdio : writeln;
        
        this.funcName = func.name;
        this.symbolTable = st;
        this.enableStackTrace = enableStackTrace;
        this.gen = NativeCodeGen.alloc(64 * 1024);  // 64KB code buffer
        this.dataSection = NativeDataSection.alloc(64 * 1024);  // 64KB data section
        this.hostFunctions = createCTFEHostFunctions();  // Milestone 88
        
        if (!gen.base) {
            throw new Exception("Failed to allocate executable memory");
        }
        if (!dataSection.base) {
            throw new Exception("Failed to allocate data section");
        }
        
        // Reserve space for inline call stack (must be before adding other data)
        if (enableStackTrace) {
            dataSection.reserveInlineStack();
        }

        // Allocate exception globals in data section
        allocateExceptionGlobals();

        // Store parameter count for call()
        this.paramCount = func.parameters.length;
        this.entryNeedsArena = func.needsArena;

        // Compile the function
        compileFunction(func);
        
        // Finalize (resolve branches, make executable)
        if (!gen.finalize()) {
            throw new Exception("Failed to finalize native code");
        }
    }
    
    /// Multi-function constructor for CTFE with dependencies
    this(FunctionDecl[] funcs, string entryFuncName, SymbolTable st, bool enableStackTrace = true,
            ImportedFunctionDecl[] imports = null) {
        import std.stdio : writeln;
        
        this.funcName = entryFuncName;
        this.symbolTable = st;
        this.enableStackTrace = enableStackTrace;
        this.gen = NativeCodeGen.alloc(64 * 1024);  // 64KB code buffer
        this.dataSection = NativeDataSection.alloc(64 * 1024);  // 64KB data section
        this.hostFunctions = createCTFEHostFunctions();  // Milestone 88
        
        if (!gen.base) {
            throw new Exception("Failed to allocate executable memory");
        }
        if (!dataSection.base) {
            throw new Exception("Failed to allocate data section");
        }
        
        // Reserve space for inline call stack (must be before adding other data)
        if (enableStackTrace) {
            dataSection.reserveInlineStack();
        }

        // Allocate exception globals in data section
        allocateExceptionGlobals();

        // Resolve extern(C) FFI imports via dlsym
        resolveFFIImports(imports);

        // Store all function decls for call resolution
        // Methods use mangled names: StructName_methodName
        foreach (func; funcs) {
            string name = getMangledName(func);
            functionDecls[name] = func;
        }

        // Create labels for all functions before compiling any
        foreach (func; funcs) {
            string name = getMangledName(func);
            functionLabels[name] = gen.newLabel();
        }
        
        // Find entry function and store its param count
        if (auto entryFunc = entryFuncName in functionDecls) {
            this.paramCount = (*entryFunc).parameters.length;
            this.entryNeedsArena = (*entryFunc).needsArena && (*entryFunc).name != "main";
        } else {
            assert(0, "Entry function not found: " ~ entryFuncName);
        }
        
        // Compile all functions
        log(1, "native: JIT compiling ", funcs.length, " functions");
        foreach (func; funcs) {
            compileFunction(func);
        }
        log(1, "native: JIT compilation done");

        // Set entry point to the entry function
        if (auto entryLabel = entryFuncName in functionLabels) {
            entryPoint = (*entryLabel).offset;
        } else {
            assert(0, "Entry function label not found: " ~ entryFuncName);
        }
        
        // Finalize (resolve branches, make executable)
        if (!gen.finalize()) {
            throw new Exception("Failed to finalize native code");
        }

        // Patch vtable entries now that function addresses are resolved
        patchVtableEntries();

    }

    /// Object-mode constructor: compiles functions into a relocatable buffer for .o output.
    /// Skips CTFE-only infrastructure (exceptions, host functions, data section).
    this(FunctionDecl[] funcs, SymbolTable st, bool objectModeFlag,
         ImportedFunctionDecl[] imports = null) {
        assert(objectModeFlag, "Use other constructors for JIT mode");
        this.objectMode = true;
        this.symbolTable = st;
        this.enableStackTrace = false;
        this.gen = NativeCodeGen.allocRelocatable(64 * 1024);

        if (!gen.base) {
            throw new Exception("Failed to allocate relocatable code buffer");
        }

        // No data section, exception globals, or host functions in object mode

        // Register extern(C) function names for call dispatch
        if (imports !is null) {
            foreach (imp; imports)
                objectExternFunctions[imp.name] = true;
        }

        foreach (func; funcs) {
            string name = getMangledName(func);
            functionDecls[name] = func;
            functionLabels[name] = gen.newLabel();
        }

        log(1, "native: object mode compiling ", funcs.length, " functions");
        foreach (func; funcs) {
            compileFunction(func);
        }
        log(1, "native: object mode compilation done");
    }

    /// Get relocatable code bytes (for object mode).
    /// Resolves internal branches, returns code as ubyte[].
    ubyte[] getRelocatableCode() {
        assert(objectMode, "getRelocatableCode only valid in object mode");
        return gen.finalizeRelocatable();
    }

    /// Get the offset of a named function within the code buffer.
    size_t getFunctionOffset(string name) {
        if (auto p = name in functionLabels)
            return (*p).offset;
        return size_t.max;
    }

    // ========== Object-mode data section and relocations ==========

    /// Get the object-mode data section bytes (for __DATA,__const).
    const(ubyte)[] getObjectData() { return objectData; }

    /// Get data symbols (local symbols in __DATA,__const).
    const(ObjectDataSymbol)[] getObjectDataSymbols() { return objectDataSymbols; }

    /// Get relocations (ADRP/ADD/BL fixups for the linker).
    const(ObjectReloc)[] getObjectRelocations() { return objectRelocations; }

    /// Get external symbol names (undefined symbols resolved by the linker).
    const(string)[] getObjectExternalSymbols() { return objectExternalSymbols; }

    /// Append data to the object data section, return its offset. 8-byte aligned.
    private uint appendObjectData(const(ubyte)[] data) {
        uint off = cast(uint)objectData.length;
        objectData ~= data;
        // Align to 8 bytes
        while (objectData.length % 8 != 0) objectData ~= 0;
        return off;
    }

    /// Emit ADRP+ADD to load the address of a data symbol into x0, recording relocations.
    private void emitLoadDataAddress(string symbolName) {
        uint adrpOff = gen.pos;
        gen.emitAdrp(0);  // ADRP x0, sym@PAGE
        objectRelocations ~= ObjectReloc(adrpOff, symbolName, RelocType.page21);

        uint addOff = gen.pos;
        gen.emitAddImm12(0, 0);  // ADD x0, x0, sym@PAGEOFF
        objectRelocations ~= ObjectReloc(addOff, symbolName, RelocType.pageoff12);
    }

    /// Emit BL to an external function, recording a BRANCH26 relocation.
    private void emitObjectExternalCall(string funcName) {
        import std.algorithm : canFind;
        if (!objectExternalSymbols.canFind(funcName))
            objectExternalSymbols ~= funcName;

        uint blOff = gen.pos;
        gen.emitExternalBranchLink();  // BL #0 (placeholder)
        objectRelocations ~= ObjectReloc(blOff, funcName, RelocType.branch26);
    }

    /// Store data and emit code to load its address into x0.
    /// JIT: stores in dataSection, emits absolute pointer load.
    /// Object: appends to objectData with symbol, emits ADRP+ADD relocation.
    private void emitDataLoad(const(ubyte)[] data, string nameHint = "__data_") {
        import std.conv : to;
        if (objectMode) {
            string symName = nameHint ~ to!string(objectDataSymCount++);
            uint dataOff = appendObjectData(data);
            objectDataSymbols ~= ObjectDataSymbol(symName, dataOff);
            emitLoadDataAddress(symName);
        } else {
            ubyte* dataPtr = dataSection.addData(data.dup);
            gen.emitLoadImm64(cast(ulong)dataPtr);
        }
    }

    /// Store a string and emit code to load its address into x0.
    private void emitStringLoad(string str, string nameHint = "__str_") {
        emitDataLoad(cast(const(ubyte)[])str, nameHint);
    }

    /// Get the mangled name for a function.
    /// Uses FunctionDecl.mangledName if set (by WASM emitter), otherwise computes it.
    private static string getMangledName(FunctionDecl func) {
        if (func.mangledName)
            return func.mangledName;
        // Fallback for native-only compilation (no WASM emitter ran)
        if (func.isMethod && func.parent !is null) {
            import codegen.mangle : computeMangledName;
            return computeMangledName([], func);
        }
        return func.name;
    }

    /// Resolve a function call to its mangled name for label/decl lookup.
    /// Handles IFTI (resolved instantiation) and regular calls via symbol table.
    private string resolveMangledName(IdentifierExpression funcIdent, CallExpression call = null) {
        // IFTI: use resolved instantiation's mangled name
        if (call && call.resolvedInstantiation)
            return getMangledName(call.resolvedInstantiation);
        // Look up symbol table for the FunctionDecl
        auto sym = symbolTable.lookupSymbol(funcIdent.name);
        if (sym && sym.declaration) {
            if (auto fd = cast(FunctionDecl)sym.declaration)
                return getMangledName(fd);
        }
        return funcIdent.name;  // fallback for builtins etc.
    }

    private void moveRegToX0(int regIdx) {
        switch (regIdx) {
            case 0: break;  // already in x0
            case 1: gen.emitMoveX1ToX0(); break;
            case 2: gen.emitMoveX2ToX0(); break;
            case 3: gen.emitMoveX3ToX0(); break;
            default: assert(0, "moveRegToX0: register index > 3 not supported");
        }
    }

    private void compileFunction(FunctionDecl func) {
        // Skip forward declarations (no body)
        if (func.body_ is null)
            return;

        string name = getMangledName(func);
        log(2, "native: compileFunction ", name, " (isMethod=", func.isMethod, ", parent=", func.parent ? func.parent.name : "null", ")");

        // Bind function label (for multi-function mode)
        if (auto labelPtr = name in functionLabels) {
            gen.bindLabel(*labelPtr);
        }
        
        // For single-function mode, track entry point
        if (functionLabels.length == 0) {
            entryPoint = gen.pos;
        }
        
        // Reset local tracking for this function
        localVars.clear();
        nextLocalOffset = 0;

        // Compute canonical parameter layout for hidden param detection
        import codegen.param_layout : computeParamLayout, ParamLayoutContext;
        import codegen.wasm.types : ValType;

        // Resolve return type and param types for accurate layout
        if (auto ut = cast(UserType)func.returnType) ut.ensureResolved(symbolTable);
        foreach (p; func.parameters)
            if (auto ut = cast(UserType)p.type) ut.ensureResolved(symbolTable);

        bool isMethod = func.isMethod && func.parent !is null &&
            (cast(StructDecl)func.parent !is null || cast(ClassDecl)func.parent !is null);
        auto layout = computeParamLayout(func, ParamLayoutContext(
            isMethod,
            func.returnType !is null && func.returnType.isLargeReturn(),
            func.needsArena,
            false,  // native backend (CTFE JIT) never suppresses arena for main
            null,       // native doesn't use WASM type mapping
            true,       // isVoidReturn — wasmResults unused by native
            ValType.i32, // dummy
            8,          // ARM64 pointer size
        ));

        // --- Allocate stack slots for hidden params (native ABI order: result_ptr, this, arena) ---

        // Hidden result pointer
        currentFunctionHasHiddenResult = layout.hasResultPtr();
        currentFunctionReturnStructDecl = null;
        currentFunctionReturnArrayBytes = 0;
        if (layout.hasResultPtr()) {
            currentFunctionResultPtrOffset = nextLocalOffset;
            nextLocalOffset += 8;  // 64-bit pointer
            assert(currentFunctionResultPtrOffset % 8 == 0,
                "Hidden result pointer offset must be 8-byte aligned for STR x0");

            // Compute return value size info (needed for return statement codegen)
            if (auto sd = func.returnType.asStruct()) {
                currentFunctionReturnStructDecl = sd;
            } else if (auto arrType = cast(ArrayType)func.returnType) {
                if (arrType.arraySize !is null) {
                    if (auto sizeLit = cast(LiteralExpression)arrType.arraySize)
                        currentFunctionReturnArrayBytes = cast(uint)sizeLit.value.get!long() * 4;
                } else {
                    currentFunctionReturnArrayBytes = sliceInfo.totalSize;
                }
            }
        } else {
            currentFunctionResultPtrOffset = 0;
        }

        // Hidden 'this' pointer (struct/class methods)
        currentMethodStruct = null;
        currentMethodClass = null;
        if (layout.hasThis()) {
            currentThisOffset = nextLocalOffset;
            NativeLocalInfo thisInfo;
            thisInfo.offset = nextLocalOffset;
            thisInfo.isReference = true;  // 'this' stores a pointer, not inline data

            if (auto sd = cast(StructDecl)func.parent) {
                currentMethodStruct = sd;
                thisInfo.kind = VarKind.struct_;
                thisInfo.structDecl = sd;
            } else if (auto cd = cast(ClassDecl)func.parent) {
                currentMethodClass = cd;
                thisInfo.kind = VarKind.class_;
                thisInfo.classDecl = cd;
            } else {
                assert(0, "Method '" ~ func.name ~ "' has 'this' but parent is neither struct nor class");
            }

            localVars["this"] = thisInfo;
            nextLocalOffset += 8;  // 64-bit pointer
            log(3, "native:   this pointer at offset ", currentThisOffset,
                " struct=", currentMethodStruct ? currentMethodStruct.name : "null",
                " class=", currentMethodClass ? currentMethodClass.name : "null");
        }

        // Hidden arena pointer
        currentFunctionHasArena = layout.hasArena();
        currentFunctionArenaOffset = 0;
        if (layout.hasArena()) {
            currentFunctionArenaOffset = nextLocalOffset;
            nextLocalOffset += 8;
        }

        // --- Allocate stack slots for user parameters ---
        foreach (param; func.parameters) {
            NativeLocalInfo nli;
            nli.offset = nextLocalOffset;

            size_t paramSize = 4;  // default for scalar
            if (auto structDecl = param.type.asStruct()) {
                assert(structDecl.structSize > 0,
                    "StructDecl '" ~ structDecl.name ~ "' has zero size - layout not computed");
                nli.kind = VarKind.struct_;
                nli.structDecl = structDecl;
                paramSize = structDecl.structSize;
            } else if (auto classDecl = param.type.asClass()) {
                assert(classDecl.classSize > 0,
                    "ClassDecl '" ~ classDecl.name ~ "' has zero size - layout not computed");
                nli.kind = VarKind.class_;
                nli.classDecl = classDecl;
                nli.isReference = true;  // classes use reference semantics
                // Align to 8 bytes for pointer storage
                nli.offset = (nextLocalOffset + 7) & ~7;
                nextLocalOffset = nli.offset;
                paramSize = 8;           // store pointer, not data copy
            } else if (auto arrayType = cast(ArrayType)param.type) {
                if (arrayType.arraySize !is null) {
                    nli.kind = VarKind.staticArray;
                    auto sizeLit = cast(LiteralExpression)arrayType.arraySize;
                    assert(sizeLit !is null, "Static array param size is not a LiteralExpression");
                    uint elemCount = cast(uint)sizeLit.value.get!long();
                    nli.staticArraySize = elemCount;
                    nli.staticArrayElemSize = 4;
                    paramSize = elemCount * 4;
                } else {
                    nli.kind = VarKind.slice;
                    nli.sliceElemSize = nativeElementSize(arrayType.elementType);
                    paramSize = sliceInfo.totalSize;
                }
            }
            localVars[param.name] = nli;
            nextLocalOffset += paramSize;
        }
        
        // Count bytes needed for locals in the body
        size_t bodyLocalBytes = countLocalBytesInStatement(func.body_);

        // Reserve temp zone for expression evaluation scratch space.
        // All temp offsets are managed by `temps` allocator (no magic arithmetic).
        size_t tempSlotOffset = nextLocalOffset + bodyLocalBytes;
        size_t tempBase = (tempSlotOffset + 7) & ~cast(size_t)7;
        enum TEMP_CAPACITY = 128;  // 8-byte-aligned slots; covers slice append (5x8=40), struct construction, expression nesting
        temps.initialize(tempBase, TEMP_CAPACITY);
        size_t totalNeeded = tempBase + TEMP_CAPACITY;
        totalLocalBytes = (totalNeeded + 15) & ~15;  // 16-byte aligned
        
        // Create epilogue label for return statements
        epilogueLabel = gen.newLabel();
        
        // Emit prologue
        if (totalLocalBytes > 0) {
            gen.emitPrologueWithLocals(totalLocalBytes);
        } else {
            gen.emitPrologue();
        }
        
        // Spill hidden params from registers to stack (native ABI order: result_ptr, this, arena)
        // Running register index tracks which ARM64 register each param arrives in.
        int regIdx = 0;

        if (currentFunctionHasHiddenResult) {
            moveRegToX0(regIdx);
            gen.emitStorePtr(currentFunctionResultPtrOffset);
            regIdx++;
        }

        if (currentMethodStruct !is null || currentMethodClass !is null) {
            moveRegToX0(regIdx);
            gen.emitStorePtr(currentThisOffset);
            regIdx++;
        }

        if (currentFunctionHasArena) {
            moveRegToX0(regIdx);
            gen.emitStorePtr(currentFunctionArenaOffset);
            regIdx++;
        }

        // Spill user parameters from registers to stack
        assert(regIdx == layout.regOffset(), "regIdx mismatch with layout.regOffset()");
        foreach (i, param; func.parameters) {
            int paramReg = cast(int)i + regIdx;
            if (paramReg >= 4) {
                throw new Exception("Native backend: more than 4 parameters not yet supported");
            }
            // Store parameter register to its stack slot
            auto nli = param.name in localVars;
            assert(nli !is null, "Parameter '" ~ param.name ~ "' not in localVars");
            size_t offset = nli.offset;

            final switch (nli.kind) {
                case VarKind.struct_:
                    // Register contains pointer to struct - copy struct data to our stack
                    switch (paramReg) {
                        case 0: gen.emitMoveX0ToX9(); break;
                        case 1: gen.emitMoveX1ToX9(); break;
                        case 2: gen.emitMoveX2ToX9(); break;
                        case 3: gen.emitMoveX3ToX9(); break;
                        default: break;
                    }
                    size_t structSize = nli.structDecl.structSize;
                    for (uint fieldOff = 0; fieldOff < structSize; fieldOff += 4) {
                        gen.emitLoadFromX9Offset(fieldOff);
                        gen.emitStoreLocal32(offset + fieldOff);
                    }
                    break;

                case VarKind.class_:
                    // Class params use reference semantics — just store the pointer
                    moveRegToX0(paramReg);
                    gen.emitStorePtr(offset);
                    break;

                case VarKind.staticArray:
                    // Register contains pointer to caller's array - copy data to our stack
                    switch (paramReg) {
                        case 0: gen.emitMoveX0ToX9(); break;
                        case 1: gen.emitMoveX1ToX9(); break;
                        case 2: gen.emitMoveX2ToX9(); break;
                        case 3: gen.emitMoveX3ToX9(); break;
                        default: break;
                    }
                    uint arrBytes = nli.staticArraySize * nli.staticArrayElemSize;
                    for (uint off = 0; off < arrBytes; off += 4) {
                        gen.emitLoadFromX9Offset(off);
                        gen.emitStoreLocal32(offset + off);
                    }
                    break;

                case VarKind.slice:
                    // Register contains pointer to caller's slice struct - copy to our stack
                    switch (paramReg) {
                        case 0: gen.emitMoveX0ToX9(); break;
                        case 1: gen.emitMoveX1ToX9(); break;
                        case 2: gen.emitMoveX2ToX9(); break;
                        case 3: gen.emitMoveX3ToX9(); break;
                        default: break;
                    }
                    for (size_t off = 0; off < sliceInfo.totalSize; off += 4) {
                        gen.emitLoadFromX9Offset(off);
                        gen.emitStoreLocal32(offset + off);
                    }
                    break;

                case VarKind.scalar:
                    // Simple scalar - store the register value
                    switch (paramReg) {
                        case 0: gen.emitStoreLocal32(offset); break;        // x0
                        case 1: gen.emitStoreLocal32FromX1(offset); break;  // x1
                        case 2: gen.emitStoreLocal32FromX2(offset); break;  // x2
                        case 3: gen.emitStoreLocal32FromX3(offset); break;  // x3
                        default: break;
                    }
                    break;
                case VarKind.delegate_:
                    assert(0, "delegate parameters not yet supported in native backend");
            }
        }
        
        // Emit inline call stack push (for error reporting) — CTFE/JIT only
        if (!objectMode) {
            string fileName = func.location.filename ? func.location.filename : "";
            emitInlinePushCall(func.name, fileName, func.location.line);
        }

        // Compile body
        if (func.body_) {
            compileStatement(func.body_);
        }

        // Bind epilogue label - return statements jump here
        gen.bindLabel(epilogueLabel);

        // Emit inline call stack pop — CTFE/JIT only
        if (!objectMode) {
            auto retSaveMark = temps.save();
            size_t retSaveSlot = temps.alloc(8);
            gen.emitStorePtr(retSaveSlot);
            gen.emitLoadImm64ToX9(cast(ulong)cast(size_t)exceptionPendingAddr);
            gen.emitLoadFromX9Offset(0);  // w0 = __exception_pending
            auto skipPopLabel = gen.newLabel();
            gen.emitBranchIfNonZero(skipPopLabel);
            emitInlinePopCall();
            gen.bindLabel(skipPopLabel);
            gen.emitLoadPtr(retSaveSlot);
            temps.restore(retSaveMark);
        }

        // Emit epilogue
        if (totalLocalBytes > 0) {
            gen.emitEpilogueWithLocals(totalLocalBytes);
        } else {
            gen.emitEpilogue();
        }
    }

    // ========== Exception Handling Helpers ==========

    /// Allocate exception globals in the data section.
    /// Two i32 scalars (pending, depth) plus a slot array (100 * 24 bytes).
    private void allocateExceptionGlobals() {
        ubyte[4] zero = [0, 0, 0, 0];
        exceptionPendingAddr = dataSection.addData(zero[]);
        exceptionDepthAddr = dataSection.addData(zero[]);
        // Pre-allocate 100 exception slots (24 bytes each)
        auto slotBytes = new ubyte[](2400);
        exceptionSlotsAddr = dataSection.addData(slotBytes);
    }

    /// Resolve extern(C) FFI imports via dlsym and store function pointers in the data section.
    private void resolveFFIImports(ImportedFunctionDecl[] imports) {
        if (imports is null) return;
        import core.sys.posix.dlfcn : dlsym;
        version (OSX) {
            import core.sys.darwin.dlfcn : RTLD_DEFAULT;
        } else {
            import core.sys.posix.dlfcn : RTLD_DEFAULT;
        }

        foreach (imp; imports) {
            if (imp.moduleName != "ffi") continue;

            // dlsym to find the native function pointer
            auto ptr = dlsym(RTLD_DEFAULT, (imp.name ~ "\0").ptr);
            if (ptr is null) continue;  // symbol not found — skip silently

            // Store the function pointer in the data section (8 bytes, aligned)
            ulong fnAddr = cast(ulong)cast(size_t)ptr;
            ubyte[8] addrBytes = (cast(ubyte*)&fnAddr)[0..8];
            ubyte* slot = dataSection.addData(addrBytes[]);
            ffiSlots[imp.name] = cast(ulong)cast(size_t)slot;
        }
    }

    /// Emit exception check after a function call (void context — result already consumed or discarded).
    /// If exception pending and inside try block: branch to catch handler.
    /// If exception pending and not in try block: branch to epilogue (propagate).
    private void emitNativeExceptionCheck() {
        if (objectMode) return; // No exception infrastructure in object mode

        // Load __exception_pending from data section
        gen.emitLoadImm64ToX9(cast(ulong)cast(size_t)exceptionPendingAddr);
        gen.emitLoadFromX9Offset(0);  // w0 = *exceptionPendingAddr
        if (tryStack.length > 0) {
            // Inside try block: branch to catch handler
            gen.emitBranchIfNonZero(tryStack[$ - 1].catchLabel);
        } else {
            // Not in try block: propagate exception by returning
            gen.emitBranchIfNonZero(epilogueLabel);
        }
    }

    /// Emit exception check after a function call that returns a value in w0/x0.
    /// Saves result to a temp slot, checks exception flag, restores on normal path.
    private void emitNativeExceptionCheckWithValue() {
        if (objectMode) return; // No exception infrastructure in object mode

        auto mark = temps.save();
        size_t savedResultOffset = temps.alloc(8);

        // Save call result (use 64-bit store to preserve pointers)
        gen.emitStorePtr(savedResultOffset);

        // Check exception flag
        gen.emitLoadImm64ToX9(cast(ulong)cast(size_t)exceptionPendingAddr);
        gen.emitLoadFromX9Offset(0);  // w0 = *exceptionPendingAddr
        if (tryStack.length > 0) {
            gen.emitBranchIfNonZero(tryStack[$ - 1].catchLabel);
        } else {
            gen.emitBranchIfNonZero(epilogueLabel);
        }

        // Restore call result on normal path (64-bit load)
        gen.emitLoadPtr(savedResultOffset);
        temps.restore(mark);
    }

    /// Compile a throw expression: write exception slot, set flag, branch to catch or epilogue.
    private void compileThrowExpression(ThrowExpression expr) {
        import codegen.error_kind : ErrorKind;

        // Evaluate the thrown value into x0
        compileExpression(expr.operand);

        // Save thrown value to a temp slot
        auto mark = temps.save();
        size_t valueTempSlot = temps.alloc(4);
        gen.emitStoreLocal32(valueTempSlot);

        // Write exception slot: slots[depth]
        emitNativeExceptionSlotWrite(ErrorKind.UserThrow, expr.location, valueTempSlot);

        temps.restore(mark);

        if (tryStack.length > 0) {
            gen.emitBranch(tryStack[$ - 1].catchLabel);
        } else {
            gen.emitBranch(epilogueLabel);
        }
    }

    /// Write an exception slot at the current depth and set __exception_pending.
    /// For UserThrow, valueTempSlot contains the thrown i32 value.
    /// For runtime errors, pass valueTempSlot = size_t.max to write 0.
    private void emitNativeExceptionSlotWrite(uint kind, SourceLocation loc, size_t valueTempSlot = size_t.max) {
        // Compute slotAddr = exceptionSlotsAddr + depth * 24
        // Load depth
        gen.emitLoadImm64ToX9(cast(ulong)cast(size_t)exceptionDepthAddr);
        gen.emitLoadFromX9Offset(0);  // w0 = depth

        // x0 = depth * 24
        gen.emitMoveX0ToX1();  // x1 = depth
        gen.emitImm32(stencil_load_imm32, 24);  // w0 = 24
        gen.emit(stencil_mul_i32);  // w0 = w1 * w0 = depth * 24

        // x0 = exceptionSlotsAddr + depth * 24
        gen.emitMoveX0ToX1();  // x1 = offset
        gen.emitLoadImm64(cast(ulong)cast(size_t)exceptionSlotsAddr);  // x0 = base
        gen.emit(stencil_add_i64);  // x0 = x1 + x0 = offset + base

        // Save slotAddr to a temp
        auto mark2 = temps.save();
        size_t slotAddrTemp = temps.alloc(8);
        gen.emitStorePtr(slotAddrTemp);

        // emitStoreToPointerFromX9 does STR w9, [x0, #offset]:
        //   x0 = address, x9 = value to store

        // Write kind (offset 0)
        gen.emitImm32(stencil_load_imm32, cast(int)kind);
        gen.emitMoveX0ToX9();  // x9 = kind (value)
        gen.emitLoadPtr(slotAddrTemp);  // x0 = slotAddr (address)
        gen.emitStoreToPointerFromX9(0);

        // Write file info: we store 0 for native (no WASM memory file strings)
        // File offset (offset 4) = 0
        gen.emitImm32(stencil_load_imm32, 0);
        gen.emitMoveX0ToX9();
        gen.emitLoadPtr(slotAddrTemp);
        gen.emitStoreToPointerFromX9(4);

        // File len (offset 8) = 0
        gen.emitImm32(stencil_load_imm32, 0);
        gen.emitMoveX0ToX9();
        gen.emitLoadPtr(slotAddrTemp);
        gen.emitStoreToPointerFromX9(8);

        // Write line (offset 12)
        gen.emitImm32(stencil_load_imm32, cast(int)loc.line);
        gen.emitMoveX0ToX9();
        gen.emitLoadPtr(slotAddrTemp);
        gen.emitStoreToPointerFromX9(12);

        // Write col (offset 16)
        gen.emitImm32(stencil_load_imm32, cast(int)loc.column);
        gen.emitMoveX0ToX9();
        gen.emitLoadPtr(slotAddrTemp);
        gen.emitStoreToPointerFromX9(16);

        // Write value (offset 20)
        if (valueTempSlot != size_t.max) {
            gen.emitLoadLocal32(valueTempSlot);  // w0 = thrown value
        } else {
            gen.emitImm32(stencil_load_imm32, 0);
        }
        gen.emitMoveX0ToX9();  // x9 = value
        gen.emitLoadPtr(slotAddrTemp);  // x0 = slotAddr
        gen.emitStoreToPointerFromX9(20);

        temps.restore(mark2);

        // Increment depth
        gen.emitLoadImm64ToX9(cast(ulong)cast(size_t)exceptionDepthAddr);
        gen.emitLoadFromX9Offset(0);  // w0 = depth
        gen.emitMoveX0ToX1();  // x1 = depth
        gen.emitImm32(stencil_load_imm32, 1);  // w0 = 1
        gen.emit(stencil_add_i32);  // w0 = w1 + w0 = depth + 1
        gen.emitMoveX0ToX9();  // x9 = depth + 1
        gen.emitLoadImm64(cast(ulong)cast(size_t)exceptionDepthAddr);  // x0 = addr
        gen.emitStoreToPointerFromX9(0);  // *addr = depth + 1

        // Set __exception_pending = 1
        gen.emitImm32(stencil_load_imm32, 1);
        gen.emitMoveX0ToX9();
        gen.emitLoadImm64(cast(ulong)cast(size_t)exceptionPendingAddr);
        gen.emitStoreToPointerFromX9(0);
    }

    /// Compile a try/catch statement using labels and the global-flag mechanism.
    private void compileTryStatement(TryStatement stmt) {
        auto catchLabel = gen.newLabel();
        auto afterLabel = gen.newLabel();

        // Allocate locals for catch parameters before emitting any code
        foreach (c; stmt.catches) {
            if (c.paramName !is null && c.paramName.length > 0) {
                if (c.paramName !in localVars) {
                    NativeLocalInfo nli;
                    nli.offset = nextLocalOffset;
                    nli.kind = VarKind.scalar;
                    localVars[c.paramName] = nli;
                    nextLocalOffset += 4;
                }
            }
        }

        // Push try context so exception checks branch to catch handler
        tryStack ~= NativeTryContext(catchLabel, afterLabel);

        // Emit try body
        compileStatement(stmt.tryBody);

        // Pop try context
        tryStack = tryStack[0 .. $ - 1];

        // Normal exit: skip catch handler
        gen.emitBranch(afterLabel);

        // Catch handler
        gen.bindLabel(catchLabel);

        // Decrement depth: depth--
        gen.emitLoadImm64ToX9(cast(ulong)cast(size_t)exceptionDepthAddr);
        gen.emitLoadFromX9Offset(0);  // w0 = depth
        // SUB w0, w0, w1: left=w0=depth, right=w1=1
        gen.emitImm32(stencil_load_imm32, 1);  // w0 = 1
        gen.emitMoveX0ToX1();  // w1 = 1
        gen.emitLoadImm64ToX9(cast(ulong)cast(size_t)exceptionDepthAddr);
        gen.emitLoadFromX9Offset(0);  // w0 = depth
        gen.emit(stencil_sub_i32);  // w0 = depth - 1
        gen.emitMoveX0ToX9();  // x9 = depth - 1
        gen.emitLoadImm64(cast(ulong)cast(size_t)exceptionDepthAddr);  // x0 = addr
        gen.emitStoreToPointerFromX9(0);  // *depthAddr = depth - 1

        // Clear __exception_pending if depth is now 0
        gen.emitLoadImm64ToX9(cast(ulong)cast(size_t)exceptionDepthAddr);
        gen.emitLoadFromX9Offset(0);  // w0 = new depth
        auto skipClearLabel = gen.newLabel();
        gen.emitBranchIfNonZero(skipClearLabel);
        // depth == 0: clear pending
        gen.emitImm32(stencil_load_imm32, 0);
        gen.emitMoveX0ToX9();
        gen.emitLoadImm64(cast(ulong)cast(size_t)exceptionPendingAddr);
        gen.emitStoreToPointerFromX9(0);
        gen.bindLabel(skipClearLabel);

        // Bind caught value and emit catch body
        if (stmt.catches.length > 0) {
            auto c = stmt.catches[0];
            if (c.paramName !is null && c.paramName.length > 0) {
                // Read value from slot[depth].value (offset 20)
                // Compute slotAddr = exceptionSlotsAddr + depth * 24
                gen.emitLoadImm64ToX9(cast(ulong)cast(size_t)exceptionDepthAddr);
                gen.emitLoadFromX9Offset(0);  // w0 = depth (already decremented)
                gen.emitMoveX0ToX1();  // x1 = depth
                gen.emitImm32(stencil_load_imm32, 24);  // w0 = 24
                gen.emit(stencil_mul_i32);  // w0 = w1 * w0 = depth * 24
                gen.emitMoveX0ToX1();  // x1 = offset
                gen.emitLoadImm64(cast(ulong)cast(size_t)exceptionSlotsAddr);  // x0 = base
                gen.emit(stencil_add_i64);  // x0 = x1 + x0 = offset + base
                gen.emitMoveX0ToX9();
                gen.emitLoadFromX9Offset(20);  // w0 = slot.value

                if (auto info = c.paramName in localVars) {
                    gen.emitStoreLocal32(info.offset);
                }
            }
            compileStatement(c.body_);
        }

        // After try/catch
        gen.bindLabel(afterLabel);
    }

    /**
     * Count bytes needed for locals in a statement (not just count of vars)
     */
    /**
     * Count stack bytes needed for expression temporaries.
     * Expressions like ArrayLiteralExpression, SliceExpression, and string literals
     * allocate temp space on the stack during code generation. This function walks
     * the expression tree to account for all such allocations so the frame size
     * is computed correctly before code generation begins.
     */
    private size_t countExpressionBytes(Expression expr) {
        if (expr is null) return 0;

        size_t bytes = 0;

        if (auto arrLit = cast(ArrayLiteralExpression)expr) {
            uint elemCount = cast(uint)arrLit.elements.length;
            uint dataSize = elemCount * 4;
            // 8-byte alignment padding + slice struct
            bytes += ((dataSize + 7) & ~7) + sliceInfo.totalSize;
            foreach (elem; arrLit.elements)
                bytes += countExpressionBytes(elem);
        } else if (auto sliceExpr = cast(SliceExpression)expr) {
            // Temp slice struct with 8-byte alignment
            bytes += 8 + sliceInfo.totalSize;
            bytes += countExpressionBytes(sliceExpr.array);
            bytes += countExpressionBytes(sliceExpr.start);
            bytes += countExpressionBytes(sliceExpr.end);
        } else if (auto lit = cast(LiteralExpression)expr) {
            if (lit.value.type == typeid(string))
                bytes += 8 + sliceInfo.totalSize;
        } else if (auto binOp = cast(BinaryExpression)expr) {
            if (binOp.operator == BinaryExpression.Operator.Concat)
                bytes += 8 + sliceInfo.totalSize;  // result slice struct
            bytes += countExpressionBytes(binOp.left);
            bytes += countExpressionBytes(binOp.right);
            bytes += countExpressionBytes(binOp.loweredCall);
        } else if (auto call = cast(CallExpression)expr) {
            bytes += countExpressionBytes(call.function_);
            foreach (arg; call.arguments)
                bytes += countExpressionBytes(arg);
        } else if (auto unary = cast(UnaryExpression)expr) {
            bytes += countExpressionBytes(unary.operand);
            bytes += countExpressionBytes(unary.loweredCall);
        } else if (auto member = cast(MemberExpression)expr) {
            bytes += countExpressionBytes(member.object);
        } else if (auto index = cast(IndexExpression)expr) {
            bytes += countExpressionBytes(index.array);
            bytes += countExpressionBytes(index.index);
        } else if (auto castExpr = cast(CastExpression)expr) {
            bytes += countExpressionBytes(castExpr.expression);
        } else if (auto assign = cast(AssignmentExpression)expr) {
            bytes += countExpressionBytes(assign.left);
            bytes += countExpressionBytes(assign.right);
            bytes += countExpressionBytes(assign.loweredCall);
        } else if (auto throwExpr = cast(ThrowExpression)expr) {
            bytes += countExpressionBytes(throwExpr.operand);
        }
        // IdentifierExpression, TraitsExpression, IsExpression, TemplateInstantiationExpression,
        // ImportExpression, ThrowExpression — no stack temp allocation (beyond operand)

        return bytes;
    }

    private size_t countLocalBytesInStatement(Statement stmt) {
        if (stmt is null) return 0;

        size_t bytes = 0;

        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                bytes += countLocalBytesInStatement(s);
            }
        } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
            // Check type to determine size
            if (auto userType = cast(UserType)varDecl.type) {
                userType.ensureResolved(symbolTable);
                if (auto sd = userType.asStruct()) {
                    // Zero-size structs (methods-only, no data fields) are valid
                    bytes = sd.structSize > 0 ? cast(uint)sd.structSize : 0;
                } else if (auto cd = userType.asClass()) {
                    if (cd.isObjC)
                        bytes = 8 + 8;  // 8-byte pointer + alignment padding
                    else
                        bytes = cd.classSize > 0 ? cast(uint)cd.classSize : 0;
                } else if (auto iface = userType.asInterface()) {
                    if (iface.isObjC)
                        bytes = 8 + 8;  // 8-byte pointer + alignment padding
                    else
                        bytes = 4;
                } else {
                    bytes = 4;
                }
            } else if (auto arrType = cast(ArrayType)varDecl.type) {
                if (arrType.arraySize is null) {
                    // Slice struct + worst-case 8-byte alignment padding
                    bytes = sliceInfo.totalSize + 8;
                    // Add data size if initialized with literal
                    if (auto arrLit = cast(ArrayLiteralExpression)varDecl.initializer) {
                        size_t elemSz = arrType.elementType.size();
                        assert(elemSz > 0, "Slice element type has zero size");
                        bytes += arrLit.elements.length * elemSz;
                    }
                } else {
                    // Static array: inline storage for N elements
                    auto sizeLit = cast(LiteralExpression)arrType.arraySize;
                    assert(sizeLit !is null, "Static array size is not a LiteralExpression");
                    assert(sizeLit.value.type == typeid(long), "Static array size literal is not a long");
                    uint length = cast(uint)sizeLit.value.get!long();
                    size_t elemSz = arrType.elementType.size();
                    assert(elemSz > 0, "Static array element type has zero size");
                    bytes = length * elemSz;
                }
            } else {
                bytes = 4;  // int, bool, etc.
            }
            // Add expression temps from initializer
            bytes += countExpressionBytes(varDecl.initializer);
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            bytes += countExpressionBytes(ifStmt.condition);
            bytes += countLocalBytesInStatement(ifStmt.thenStatement);
            bytes += countLocalBytesInStatement(ifStmt.elseStatement);
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            bytes += countExpressionBytes(whileStmt.condition);
            bytes += countLocalBytesInStatement(whileStmt.body_);
        } else if (auto forStmt = cast(ForStatement)stmt) {
            bytes += countLocalBytesInStatement(forStmt.init);
            bytes += countExpressionBytes(forStmt.condition);
            bytes += countExpressionBytes(forStmt.update);
            bytes += countLocalBytesInStatement(forStmt.body_);
        } else if (auto retStmt = cast(ReturnStatement)stmt) {
            bytes += countExpressionBytes(retStmt.value);
        } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
            bytes += countExpressionBytes(exprStmt.expression);
        } else if (auto tryStmt = cast(TryStatement)stmt) {
            bytes += countLocalBytesInStatement(tryStmt.tryBody);
            foreach (c; tryStmt.catches) {
                if (c.paramName !is null && c.paramName.length > 0)
                    bytes += 4;  // catch parameter (i32)
                bytes += countLocalBytesInStatement(c.body_);
            }
            if (tryStmt.finallyBody !is null)
                bytes += countLocalBytesInStatement(tryStmt.finallyBody);
        } else if (cast(BreakStatement)stmt || cast(ContinueStatement)stmt
                   || cast(MixinStatement)stmt || cast(StructDeclarationStatement)stmt) {
            // No local allocations
        } else {
            assert(0, "countLocalBytesInStatement: unhandled statement type: " ~ typeid(stmt).name);
        }

        return bytes;
    }
    
    private void compileStatement(Statement stmt) {
        log(3, "native: stmt ", typeid(stmt));
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                compileStatement(s);
            }
        } else if (auto ret = cast(ReturnStatement)stmt) {
            if (ret.value) {
                if (currentFunctionHasHiddenResult) {
                    // Unified large return: copy N bytes from source to result pointer
                    // Works for structs, static arrays, and slices — all use the same mechanism
                    size_t returnSize = 0;
                    if (currentFunctionReturnStructDecl !is null)
                        returnSize = currentFunctionReturnStructDecl.structSize;
                    else if (currentFunctionReturnArrayBytes > 0)
                        returnSize = currentFunctionReturnArrayBytes;

                    if (returnSize > 0) {
                        // Allocate srcTempSlot BEFORE compileExpression so that
                        // struct construction (which also uses temps) gets a
                        // non-overlapping offset.
                        auto returnMark = temps.save();
                        size_t srcTempSlot = temps.alloc(8);

                        compileExpression(ret.value);  // x0 = source address
                        gen.emitStorePtr(srcTempSlot);  // Save 64-bit ptr

                        for (size_t off = 0; off < returnSize; off += 4) {
                            gen.emitLoadPtr(srcTempSlot);      // x0 = src ptr
                            gen.emitLoadFromPointer(off);        // x0 = *(src + off)
                            gen.emitMoveX0ToX9();                // x9 = value

                            gen.emitLoadPtr(currentFunctionResultPtrOffset);  // x0 = dest ptr
                            gen.emitStoreToPointerFromX9(off);   // *(dest + off) = x9
                        }

                        temps.restore(returnMark);
                    }
                } else {
                    compileExpression(ret.value);
                }
            }
            // Jump to epilogue (which will restore stack and return)
            gen.emitBranch(epilogueLabel);
        } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
            compileExpression(exprStmt.expression);
        } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
            // Check if this is a struct type or slice type
            StructDecl structType = null;
            ClassDecl classType = null;
            bool isSlice = false;
            uint staticArrayLength = 0;
            size_t varSize = 4;  // default to 4 bytes for int

            bool isObjCRef = false;
            InterfaceDecl objcIface = null;
            if (auto userType = cast(UserType)varDecl.type) {
                userType.ensureResolved(symbolTable);
                if (auto sd = userType.asStruct()) {
                    // Zero-size structs (methods-only, no data fields) are valid
                    structType = sd;
                    varSize = sd.structSize > 0 ? sd.structSize : 0;
                } else if (auto cd = userType.asClass()) {
                    if (cd.isObjC) {
                        // ObjC classes are opaque pointers (8 bytes), no vtable
                        classType = cd;
                        isObjCRef = true;
                        varSize = 8;
                    } else {
                        classType = cd;
                        varSize = cd.classSize > 0 ? cd.classSize : 0;
                    }
                } else if (auto iface = userType.asInterface()) {
                    if (iface.isObjC) {
                        // ObjC interface = opaque pointer (8 bytes)
                        isObjCRef = true;
                        objcIface = iface;
                        varSize = 8;
                    }
                }
            } else if (auto arrType = cast(ArrayType)varDecl.type) {
                if (arrType.arraySize is null) {
                    // Dynamic array (slice) = sliceInfo.totalSize bytes on native (64-bit ptr)
                    isSlice = true;
                    varSize = sliceInfo.totalSize;
                    // Add data size if initialized with literal
                    if (auto arrLit = cast(ArrayLiteralExpression)varDecl.initializer) {
                        varSize += arrLit.elements.length * 4;
                    }
                } else {
                    // Static array: inline storage for N elements
                    auto sizeLit = cast(LiteralExpression)arrType.arraySize;
                    assert(sizeLit !is null, "Static array size is not a LiteralExpression");
                    assert(sizeLit.value.type == typeid(long), "Static array size literal is not a long");
                    uint length = cast(uint)sizeLit.value.get!long();
                    size_t elemSz = arrType.elementType.size();
                    if (elemSz == 0) elemSz = 4;
                    varSize = length * elemSz;
                    staticArrayLength = length;
                }
            } else if (cast(PointerType)varDecl.type !is null) {
                // Raw pointer: 8 bytes on ARM64
                varSize = 8;
            }
            
            // Allocate stack slot for this variable
            // Slices, ObjC refs, and raw pointers contain a 64-bit value and need 8-byte alignment
            // for STR x0, [sp, #imm] encoding (imm must be multiple of 8)
            bool isPtr = cast(PointerType)varDecl.type !is null;
            if (isSlice || isObjCRef || isPtr) {
                nextLocalOffset = (nextLocalOffset + 7) & ~7;
            }
            NativeLocalInfo nli;
            nli.offset = nextLocalOffset;
            if (structType) {
                nli.kind = VarKind.struct_;
                nli.structDecl = structType;
            } else if (isSlice) {
                nli.kind = VarKind.slice;
                if (auto at = cast(ArrayType)varDecl.type) {
                    nli.elementType = at.elementType;
                    nli.sliceElemSize = nativeElementSize(at.elementType);
                } else {
                    nli.sliceElemSize = 4;
                }
            } else if (classType) {
                nli.kind = VarKind.class_;
                nli.classDecl = classType;
            } else if (objcIface) {
                // ObjC interface: opaque 8-byte pointer, not a D class
                nli.interfaceDecl = objcIface;
            } else if (staticArrayLength > 0) {
                nli.kind = VarKind.staticArray;
                nli.staticArraySize = staticArrayLength;
                if (auto at = cast(ArrayType)varDecl.type) {
                    nli.elementType = at.elementType;
                    nli.staticArrayElemSize = cast(uint)at.elementType.size();
                    if (nli.staticArrayElemSize == 0) nli.staticArrayElemSize = 4;
                } else {
                    nli.staticArrayElemSize = 4;
                }
            }
            // else: kind stays VarKind.scalar (default)
            if (isObjCRef)
                nli.isObjCRef = true;
            if (isPtr)
                nli.isRawPointer = true;
            localVars[varDecl.name] = nli;

            // Zero-initialize variables without explicit initializer
            // (D guarantees .init = 0 for int types, null for slices)
            if (!varDecl.initializer && varSize > 0) {
                if (nli.isStaticArray || nli.isStruct || nli.isSlice || (nli.isClass && !isObjCRef)) {
                    gen.emitImm32(stencil_load_imm32, 0);
                    for (size_t off = 0; off < varSize; off += 4) {
                        gen.emitStoreLocal32(nli.offset + off);
                    }
                } else if (isObjCRef || isPtr) {
                    // ObjC ref / raw pointer: zero 8-byte value
                    gen.emitLoadImm64(0);
                    gen.emitStorePtr(nli.offset);
                } else if (nli.kind == VarKind.scalar) {
                    gen.emitImm32(stencil_load_imm32, 0);
                    gen.emitStoreLocal32(nli.offset);
                }
            }

            // Class vtable pointer initialization: store table base index at offset 0
            // Skip for ObjC classes — they use objc_msgSend, not D vtables
            if (nli.isClass && classType && !isObjCRef) {
                log(2, "native: class var '", varDecl.name, "' type=", classType.name, " size=", classType.classSize);
                ensureNativeVtable(classType);
                uint tableBase = classTableBases[classType.name];
                gen.emitImm32(stencil_load_imm32, cast(int)tableBase);
                gen.emitStoreLocal32(nli.offset);  // vtable ptr at offset 0
            }

            // Compile initializer if present
            if (varDecl.initializer) {
                if (isObjCRef) {
                    // ObjC ref: compile expression (objc_msgSend returns pointer in x0)
                    // and store as 8-byte pointer
                    compileExpression(varDecl.initializer);
                    gen.emitStorePtr(nli.offset);
                } else if (nli.isStruct) {
                    // Unwrap lowered operator overload calls
                    Expression effectiveInit = varDecl.initializer;
                    if (auto binary = cast(BinaryExpression)effectiveInit) {
                        if (binary.loweredCall) effectiveInit = binary.loweredCall;
                    }
                    if (auto unary = cast(UnaryExpression)effectiveInit) {
                        if (unary.loweredCall) effectiveInit = unary.loweredCall;
                    }

                    // Struct template construction: Pair!(int, int)(10, 20)
                    if (auto tmplInst = cast(TemplateInstantiationExpression)effectiveInit) {
                        if (tmplInst.resolvedStructInstantiation) {
                            auto sd = tmplInst.resolvedStructInstantiation;
                            for (size_t i = 0; i < sd.fields.length && i < tmplInst.callArguments.length; i++) {
                                auto field = sd.fields[i];
                                size_t fieldOffset = nextLocalOffset + field.offset;
                                compileExpression(tmplInst.callArguments[i]);
                                gen.emitStoreLocal32(fieldOffset);
                            }
                        }
                    } else if (auto call = cast(CallExpression)effectiveInit) {
                        if (auto funcIdent = cast(IdentifierExpression)call.function_) {
                            auto symbol = symbolTable.lookupSymbol(funcIdent.name);
                            assert(symbol !is null,
                                "Struct var '" ~ varDecl.name ~ "' initializer calls '" ~
                                funcIdent.name ~ "' which is not in symbol table");
                            assert(symbol.kind == SymbolKind.Type || symbol.kind == SymbolKind.Function,
                                "Struct var '" ~ varDecl.name ~ "' initializer calls '" ~
                                funcIdent.name ~ "' which is neither Type nor Function");
                            if (symbol && symbol.kind == SymbolKind.Type) {
                                if (auto sd = symbol.type.asStruct()) {
                                        // Initialize struct fields directly at our variable's location
                                        for (size_t i = 0; i < sd.fields.length && i < call.arguments.length; i++) {
                                            auto field = sd.fields[i];
                                            size_t fieldOffset = nextLocalOffset + field.offset;
                                            uint valueSize = cast(uint)field.type.size();
                                            
                                            // Aggregate types (struct, class, static array) are passed
                                            // by address — need to copy their data, not store address
                                            if (field.type.isAggregate() && valueSize > 0) {
                                                compileExpression(call.arguments[i]);  // x0 = address of source
                                                // Copy word by word
                                                for (uint off = 0; off < valueSize; off += 4) {
                                                    gen.emitLoadFromPointer(off);
                                                    gen.emitStoreLocal32(fieldOffset + off);
                                                    if (off + 4 < valueSize) {
                                                        compileExpression(call.arguments[i]);  // reload src addr
                                                    }
                                                }
                                                continue;
                                            }
                                            
                                            compileExpression(call.arguments[i]);
                                            gen.emitStoreLocal32(fieldOffset);
                                        }
                                }
                            } else if (symbol && symbol.kind == SymbolKind.Function) {
                                // Function call returning struct — hidden result pointer pattern
                                // ARM64: x0 = result ptr, [x1 = arena], x1/x2..xN = actual args
                                string structCallName = resolveMangledName(funcIdent, call);
                                assert((structCallName in functionLabels) !is null,
                                    "Struct return call to '" ~ structCallName ~
                                    "' but no function label exists");

                                // Check if callee needs arena
                                bool calleeNeedsArena = false;
                                if (auto calleeDecl = structCallName in functionDecls) {
                                    calleeNeedsArena = (*calleeDecl).needsArena;
                                }
                                int arenaShift = calleeNeedsArena ? 1 : 0;

                                // First, compile and save all arguments to temp slots
                                size_t tempOffset = nextLocalOffset + varSize;
                                size_t[] argTemps;
                                foreach (arg; call.arguments) {
                                    compileExpression(arg);
                                    gen.emitStoreLocal32(tempOffset);
                                    argTemps ~= tempOffset;
                                    tempOffset += 4;
                                }

                                // Load args into registers in reverse order
                                // User args go into x(1+arenaShift), x(2+arenaShift), ...
                                for (long i = cast(long)argTemps.length - 1; i >= 0; i--) {
                                    gen.emitLoadLocal32(argTemps[cast(size_t)i]);
                                    switch (cast(int)i + 1 + arenaShift) {
                                        case 1: gen.emitMoveX0ToX1(); break;
                                        case 2: gen.emitMoveX0ToX2(); break;
                                        case 3: gen.emitMoveX0ToX3(); break;
                                        default: assert(0, "argument register > 3");
                                    }
                                }

                                // Load arena into x1 if callee needs it
                                if (calleeNeedsArena) {
                                    gen.emitLoadPtr(currentFunctionArenaOffset);
                                    gen.emitMoveX0ToX1();
                                }

                                // Load result address into x0 (first arg)
                                gen.emitStackAddress(nextLocalOffset);

                                // Call the function
                                auto funcLabelPtr = structCallName in functionLabels;
                                if (funcLabelPtr is null) {
                                    throw new Exception("Function not compiled: " ~ structCallName);
                                }
                                gen.emitCall(*funcLabelPtr);
                                emitNativeExceptionCheck();
                                // Result is now written to nextLocalOffset
                            }
                        } else if (auto memberFunc = cast(MemberExpression)call.function_) {
                            // Method call returning struct: Point p = s.origin()
                            // Dispatch to struct-returning method call (virtual or direct)
                            emitStructReturnMethodCallNative(memberFunc, call.arguments, nextLocalOffset);
                        }
                    }
                } else if (nli.isClass) {
                    // Class construction: ClassName(arg1, arg2, ...)
                    // Vtable pointer at offset 0 is already set above.
                    // Fields are initialized from constructor arguments.
                    if (auto call = cast(CallExpression)varDecl.initializer) {
                        if (auto funcIdent = cast(IdentifierExpression)call.function_) {
                            auto symbol = symbolTable.lookupSymbol(funcIdent.name);
                            if (symbol && symbol.kind == SymbolKind.Type) {
                                if (auto cd = symbol.type.asClass()) {
                                    assert(cd is classType,
                                        "Class init type mismatch: expected " ~
                                        classType.name ~ " but got " ~ cd.name);
                                    // Initialize fields directly at our variable's location
                                    for (size_t i = 0; i < cd.fields.length && i < call.arguments.length; i++) {
                                        auto field = cd.fields[i];
                                        size_t fieldOffset = nextLocalOffset + field.offset;
                                        uint valueSize = cast(uint)field.type.size();

                                        // Aggregate types are passed by address — copy data
                                        if (field.type.isAggregate() && valueSize > 0) {
                                            compileExpression(call.arguments[i]);
                                            for (uint off = 0; off < valueSize; off += 4) {
                                                gen.emitLoadFromPointer(off);
                                                gen.emitStoreLocal32(fieldOffset + off);
                                                if (off + 4 < valueSize) {
                                                    compileExpression(call.arguments[i]);
                                                }
                                            }
                                            continue;
                                        }

                                        compileExpression(call.arguments[i]);
                                        gen.emitStoreLocal32(fieldOffset);
                                    }
                                }
                            }
                        }
                    }
                } else if (nli.isSlice) {
                    // Unwrap reinterpret casts — no-op for same-layout slices
                    Expression sliceInit = varDecl.initializer;
                    if (auto castExpr = cast(CastExpression)sliceInit)
                        sliceInit = castExpr.expression;

                    // Slice initialization from array literal, string literal, or import()
                    if (auto arrLit = cast(ArrayLiteralExpression)sliceInit) {
                        compileSliceInit(nextLocalOffset, arrLit);
                    } else if (auto importExpr = cast(ImportExpression)sliceInit) {
                        // Milestone 86: import() in native backend
                        compileImportInit(nextLocalOffset, importExpr);
                    } else if (auto litExpr = cast(LiteralExpression)sliceInit) {
                        if (litExpr.value.type == typeid(string)) {
                            compileStringLiteralInit(nextLocalOffset, litExpr.value.get!string());
                        } else {
                            throw new Exception("Unsupported literal type for slice init");
                        }
                    } else if (auto sliceExpr = cast(SliceExpression)sliceInit) {
                        // Slice init from another array: int[] s = arr[1..4]
                        auto sourceIdent = cast(IdentifierExpression)sliceExpr.array;
                        if (!sourceIdent)
                            throw new Exception("Complex slice source not supported in native slice init");
                        auto srcInfo = sourceIdent.name in localVars;
                        if (srcInfo is null || (!srcInfo.isSlice && !srcInfo.isStaticArray))
                            throw new Exception("Can only slice array-like variables in native slice init");
                        uint srcElemSize = srcInfo.elemSize;

                        // Compute ptr = base + start * elemSize → store at nli.offset
                        if (srcInfo.isSlice) {
                            gen.emitLoadPtr(srcInfo.offset);  // 64-bit ptr
                        } else {
                            gen.emitStackAddress(srcInfo.offset);  // static array address
                        }
                        gen.emitMoveX0ToX9();  // x9 = base ptr
                        compileExpression(sliceExpr.start);
                        gen.emitMoveX0ToX1();
                        gen.emitImm32(stencil_load_imm32, srcElemSize);
                        gen.emit(stencil_mul_i32);  // x0 = start * elemSize
                        gen.emitMoveX0ToX1();
                        gen.emitMoveX9ToX0();
                        gen.emit(stencil_add_i64);  // x0 = base + start * elemSize (64-bit ptr)
                        gen.emitStorePtr(nli.offset);  // store 64-bit ptr

                        // Compute length = end - start → store at nli.offset + LENGTH_OFFSET
                        compileExpression(sliceExpr.end);
                        gen.emitMoveX0ToX9();
                        compileExpression(sliceExpr.start);
                        gen.emitMoveX0ToX1();
                        gen.emitMoveX9ToX0();
                        gen.emit(stencil_sub_i32);  // x0 = end - start
                        gen.emitStoreLocal32(nli.offset + sliceInfo.lengthOffset);

                        // Capacity = length
                        compileExpression(sliceExpr.end);
                        gen.emitMoveX0ToX9();
                        compileExpression(sliceExpr.start);
                        gen.emitMoveX0ToX1();
                        gen.emitMoveX9ToX0();
                        gen.emit(stencil_sub_i32);
                        gen.emitStoreLocal32(nli.offset + sliceInfo.capacityOffset);
                    } else if (auto callExpr = cast(CallExpression)sliceInit) {
                        // Function call returning slice — hidden result pointer pattern
                        if (auto funcIdent = cast(IdentifierExpression)callExpr.function_) {
                            string sliceCallName = resolveMangledName(funcIdent, callExpr);
                            auto funcLabelPtr = sliceCallName in functionLabels;
                            if (funcLabelPtr is null)
                                throw new Exception("Function not compiled: " ~ sliceCallName);

                            bool calleeNeedsArena = false;
                            if (auto calleeDecl = sliceCallName in functionDecls)
                                calleeNeedsArena = (*calleeDecl).needsArena;
                            int arenaShift = calleeNeedsArena ? 1 : 0;

                            // Compile and save all arguments to temp slots (64-bit for pointer args)
                            size_t tempOffset = (nextLocalOffset + varSize + 7) & ~7;  // 8-byte align
                            size_t[] argTemps;
                            foreach (arg; callExpr.arguments) {
                                compileExpression(arg);
                                gen.emitStorePtr(tempOffset);  // 64-bit store — pointers need full width
                                argTemps ~= tempOffset;
                                tempOffset += 8;
                            }

                            // Load args into registers (user args after result ptr + arena)
                            for (long i = cast(long)argTemps.length - 1; i >= 0; i--) {
                                gen.emitLoadPtr(argTemps[cast(size_t)i]);  // 64-bit load
                                switch (cast(int)i + 1 + arenaShift) {
                                    case 1: gen.emitMoveX0ToX1(); break;
                                    case 2: gen.emitMoveX0ToX2(); break;
                                    case 3: gen.emitMoveX0ToX3(); break;
                                    default: assert(0, "argument register > 3");
                                }
                            }

                            // Load arena into x1 if callee needs it
                            if (calleeNeedsArena) {
                                gen.emitLoadPtr(currentFunctionArenaOffset);
                                gen.emitMoveX0ToX1();
                            }

                            // x0 = result ptr (stack address of this slice variable)
                            gen.emitStackAddress(nli.offset);

                            gen.emitCall(*funcLabelPtr);
                            emitNativeExceptionCheck();
                        } else {
                            throw new Exception("Complex call target not supported for slice init");
                        }
                    } else if (auto identInit = cast(IdentifierExpression)sliceInit) {
                        // Manifest constant initializer: string[] arr = MANIFEST;
                        auto sym = symbolTable.lookupSymbol(identInit.name);
                        if (sym && sym.isConstant) {
                            if (auto manifest = cast(ManifestConstantDecl)sym.declaration) {
                                manifest.ensureEvaluated();
                                if (manifest.isNestedArrayType) {
                                    // Build nested array data in data section
                                    uint outerCount = cast(uint)manifest.ctfeNestedElements.length;
                                    uint innerElemSize = manifest.ctfeInnerElementSize;

                                    if (objectMode) {
                                        // Object mode: need unsigned64 relocations for inner pointers
                                        // Store each inner array, collect offsets and symbols
                                        import std.conv : to;
                                        string[] innerSyms = new string[outerCount];
                                        uint[] innerLens = new uint[outerCount];
                                        foreach (i; 0 .. outerCount) {
                                            ubyte[] innerBytes = manifest.ctfeNestedElements[i];
                                            innerSyms[i] = "__nested_inner_" ~ to!string(objectDataSymCount++);
                                            uint off = appendObjectData(innerBytes);
                                            objectDataSymbols ~= ObjectDataSymbol(innerSyms[i], off);
                                            innerLens[i] = innerElemSize > 0
                                                ? cast(uint)innerBytes.length / innerElemSize
                                                : cast(uint)innerBytes.length;
                                        }

                                        // Build inner slice structs with zero pointers (will be relocated)
                                        ubyte[] innerStructsData = new ubyte[outerCount * sliceInfo.totalSize];
                                        foreach (i; 0 .. outerCount) {
                                            size_t base = i * sliceInfo.totalSize;
                                            // pointer slot left as zero — relocation fills it
                                            *cast(uint*)&innerStructsData[base + sliceInfo.lengthOffset] = innerLens[i];
                                            *cast(uint*)&innerStructsData[base + sliceInfo.capacityOffset] = innerLens[i];
                                        }
                                        string outerSym = "__nested_outer_" ~ to!string(objectDataSymCount++);
                                        uint outerOff = appendObjectData(innerStructsData);
                                        objectDataSymbols ~= ObjectDataSymbol(outerSym, outerOff);

                                        // Add unsigned64 relocations for each inner pointer slot
                                        foreach (i; 0 .. outerCount) {
                                            uint slotOff = outerOff + cast(uint)(i * sliceInfo.totalSize);
                                            objectRelocations ~= ObjectReloc(slotOff, innerSyms[i], RelocType.unsigned64, 1);
                                        }

                                        emitLoadDataAddress(outerSym);
                                    } else {
                                        // JIT mode: embed absolute pointers directly
                                        ubyte*[] innerDataPtrs = new ubyte*[outerCount];
                                        uint[] innerLens = new uint[outerCount];
                                        foreach (i; 0 .. outerCount) {
                                            ubyte[] innerBytes = manifest.ctfeNestedElements[i];
                                            innerDataPtrs[i] = dataSection.addData(innerBytes);
                                            innerLens[i] = innerElemSize > 0
                                                ? cast(uint)innerBytes.length / innerElemSize
                                                : cast(uint)innerBytes.length;
                                        }

                                        ubyte[] innerStructsData = new ubyte[outerCount * sliceInfo.totalSize];
                                        foreach (i; 0 .. outerCount) {
                                            size_t base = i * sliceInfo.totalSize;
                                            *cast(ulong*)&innerStructsData[base] = cast(ulong)innerDataPtrs[i];
                                            *cast(uint*)&innerStructsData[base + sliceInfo.lengthOffset] = innerLens[i];
                                            *cast(uint*)&innerStructsData[base + sliceInfo.capacityOffset] = innerLens[i];
                                        }
                                        ubyte* innerStructsPtr = dataSection.addData(innerStructsData);
                                        gen.emitLoadImm64(cast(ulong)innerStructsPtr);
                                    }

                                    // Initialize local slice: ptr = address in x0, len = outerCount, cap = outerCount
                                    gen.emitStorePtr(nli.offset);
                                    gen.emitImm32(stencil_load_imm32, cast(int)outerCount);
                                    gen.emitStoreLocal32(nli.offset + sliceInfo.lengthOffset);
                                    gen.emitImm32(stencil_load_imm32, cast(int)outerCount);
                                    gen.emitStoreLocal32(nli.offset + sliceInfo.capacityOffset);
                                } else if (manifest.isArrayType) {
                                    // Flat array manifest: build data in data section
                                    uint elemSize = manifest.ctfeElementSize > 0 ? manifest.ctfeElementSize : 4;
                                    uint elemCount = cast(uint)manifest.ctfeArrayBytes.length / elemSize;

                                    emitDataLoad(manifest.ctfeArrayBytes, "__manifest_");
                                    gen.emitStorePtr(nli.offset);
                                    gen.emitImm32(stencil_load_imm32, cast(int)elemCount);
                                    gen.emitStoreLocal32(nli.offset + sliceInfo.lengthOffset);
                                    gen.emitImm32(stencil_load_imm32, cast(int)elemCount);
                                    gen.emitStoreLocal32(nli.offset + sliceInfo.capacityOffset);
                                } else {
                                    throw new Exception("Unsupported manifest type for slice init: " ~ manifest.name);
                                }
                            } else {
                                throw new Exception("Non-manifest constant used as slice initializer: " ~ identInit.name);
                            }
                        } else if (auto srcInfo = identInit.name in localVars) {
                            if (srcInfo.isSlice) {
                                // Copy slice struct from local/param variable
                                gen.emitStackAddress(srcInfo.offset);
                                gen.emitMoveX0ToX9();
                                for (size_t off = 0; off < sliceInfo.totalSize; off += 4) {
                                    gen.emitLoadFromX9Offset(off);
                                    gen.emitStoreLocal32(nli.offset + off);
                                }
                            } else {
                                throw new NativeCompileError("identifier '" ~ identInit.name ~ "' is not a slice variable", varDecl.location);
                            }
                        } else {
                            throw new NativeCompileError("unknown identifier for slice init: " ~ identInit.name, varDecl.location);
                        }
                    } else if (auto binExpr = cast(BinaryExpression)sliceInit) {
                        if (binExpr.operator == BinaryExpression.Operator.Concat) {
                            // Advance past slice var before concat (concat allocates frame space too)
                            nextLocalOffset += varSize;
                            // Concat produces slice struct address in x0
                            compileArrayConcat(binExpr);
                            gen.emitMoveX0ToX9();
                            for (size_t off = 0; off < sliceInfo.totalSize; off += 4) {
                                gen.emitLoadFromX9Offset(off);
                                gen.emitStoreLocal32(nli.offset + off);
                            }
                            varSize = 0;  // already advanced
                        } else {
                            throw new NativeCompileError("unsupported binary operator for slice init", varDecl.location);
                        }
                    } else {
                        throw new NativeCompileError("slice variable '" ~ varDecl.name
                            ~ "' can only be initialized from array literal, string literal, slice, call, or import()"
                            ~ " (got " ~ typeid(sliceInit).name ~ ")",
                            varDecl.location);
                    }
                } else if (nli.isStaticArray) {
                    // Static array initialization from array literal
                    if (auto arrLit = cast(ArrayLiteralExpression)varDecl.initializer) {
                        // Store each element directly on stack
                        foreach (i, elem; arrLit.elements) {
                            compileExpression(elem);
                            gen.emitStoreLocal32(nextLocalOffset + i * 4);
                        }
                    } else if (auto call = cast(CallExpression)varDecl.initializer) {
                        // Function call returning static array — hidden result pointer
                        if (auto funcIdent = cast(IdentifierExpression)call.function_) {
                            string saCallName = resolveMangledName(funcIdent, call);
                            auto funcLabelPtr = saCallName in functionLabels;
                            if (funcLabelPtr is null)
                                throw new Exception("Function not compiled: " ~ saCallName);

                            // Check if callee needs arena
                            bool calleeNeedsArena = false;
                            if (auto calleeDecl = saCallName in functionDecls) {
                                calleeNeedsArena = (*calleeDecl).needsArena;
                            }
                            int arenaShift = calleeNeedsArena ? 1 : 0;

                            // Compile and save all arguments to temp slots
                            size_t tempOffset = nextLocalOffset + varSize;
                            size_t[] argTemps;
                            foreach (arg; call.arguments) {
                                compileExpression(arg);
                                gen.emitStoreLocal32(tempOffset);
                                argTemps ~= tempOffset;
                                tempOffset += 4;
                            }

                            // Load args into registers in reverse order
                            // User args go into x(1+arenaShift), x(2+arenaShift), ...
                            for (long i = cast(long)argTemps.length - 1; i >= 0; i--) {
                                gen.emitLoadLocal32(argTemps[cast(size_t)i]);
                                switch (cast(int)i + 1 + arenaShift) {
                                    case 1: gen.emitMoveX0ToX1(); break;
                                    case 2: gen.emitMoveX0ToX2(); break;
                                    case 3: gen.emitMoveX0ToX3(); break;
                                    default: assert(0, "argument register > 3");
                                }
                            }

                            // Load arena into x1 if callee needs it
                            if (calleeNeedsArena) {
                                gen.emitLoadPtr(currentFunctionArenaOffset);
                                gen.emitMoveX0ToX1();
                            }

                            // x0 = result address (stack address of static array)
                            gen.emitStackAddress(nextLocalOffset);
                            gen.emitCall(*funcLabelPtr);
                            emitNativeExceptionCheck();
                        } else {
                            throw new Exception("Static array init from non-identifier call not supported");
                        }
                    } else {
                        throw new Exception("Static array can only be initialized from array literal or function call");
                    }
                } else {
                    size_t varOffset = nli.offset;
                    nextLocalOffset += varSize;  // advance past variable before compiling initializer
                    compileExpression(varDecl.initializer);
                    if (nli.isRawPointer || nli.isObjCRef)
                        gen.emitStorePtr(varOffset);
                    else
                        gen.emitStoreLocal32(varOffset);
                    varSize = 0;  // already advanced
                }
            }

            nextLocalOffset += varSize;
            assert(nextLocalOffset <= temps.tempBase(),
                "Frame overflow in var decl: nextLocalOffset exceeds temp zone");
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            // Compile: if (cond) { then } else { else }
            auto elseLabel = gen.newLabel();
            auto endLabel = gen.newLabel();
            
            // Compile condition (result in x0)
            compileExpression(ifStmt.condition);
            
            // Branch to else if condition is zero
            gen.emitBranchIfZero(elseLabel);
            
            // Compile then branch
            compileStatement(ifStmt.thenStatement);
            
            if (ifStmt.elseStatement) {
                // Jump over else branch
                gen.emitBranch(endLabel);
            }
            
            // Else branch (or just the end if no else)
            gen.bindLabel(elseLabel);
            if (ifStmt.elseStatement) {
                compileStatement(ifStmt.elseStatement);
            }
            
            gen.bindLabel(endLabel);
            
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            // Compile: while (cond) { body }
            auto loopStart = gen.newLabel();
            auto loopEnd = gen.newLabel();

            nativeLoopStack ~= NativeLoopContext(loopEnd, loopStart);

            // Loop start (continue target)
            gen.bindLabel(loopStart);

            // Compile condition (result in x0)
            compileExpression(whileStmt.condition);

            // Exit loop if condition is zero
            gen.emitBranchIfZero(loopEnd);

            // Compile body
            compileStatement(whileStmt.body_);

            // Jump back to start
            gen.emitBranch(loopStart);

            // Loop end (break target)
            gen.bindLabel(loopEnd);

            nativeLoopStack = nativeLoopStack[0 .. $ - 1];
        } else if (auto forStmt = cast(ForStatement)stmt) {
            // Compile: for (init; cond; update) { body }
            auto loopStart = gen.newLabel();
            auto loopEnd = gen.newLabel();
            auto updateLabel = gen.newLabel();

            // Compile init (if present)
            if (forStmt.init) {
                compileStatement(forStmt.init);
            }

            nativeLoopStack ~= NativeLoopContext(loopEnd, updateLabel);

            // Loop start
            gen.bindLabel(loopStart);

            // Compile condition (if present, result in x0)
            if (forStmt.condition) {
                compileExpression(forStmt.condition);
                // Exit loop if condition is zero
                gen.emitBranchIfZero(loopEnd);
            }

            // Compile body
            compileStatement(forStmt.body_);

            // Update (continue target)
            gen.bindLabel(updateLabel);
            if (forStmt.update) {
                compileExpression(forStmt.update);
            }

            // Jump back to start
            gen.emitBranch(loopStart);

            // Loop end (break target)
            gen.bindLabel(loopEnd);

            nativeLoopStack = nativeLoopStack[0 .. $ - 1];
        } else if (cast(BreakStatement)stmt) {
            if (nativeLoopStack.length == 0)
                throw new Exception("break statement outside of loop");
            gen.emitBranch(nativeLoopStack[$ - 1].breakLabel);
        } else if (cast(ContinueStatement)stmt) {
            if (nativeLoopStack.length == 0)
                throw new Exception("continue statement outside of loop");
            gen.emitBranch(nativeLoopStack[$ - 1].continueLabel);
        } else if (auto tryStmt = cast(TryStatement)stmt) {
            compileTryStatement(tryStmt);
        } else if (cast(StructDeclarationStatement)stmt) {
            // Inner struct declaration — no runtime code
        } else if (auto mixinStmt = cast(MixinStatement)stmt) {
            if (mixinStmt.isExpanded) {
                foreach (s; mixinStmt.expandedStatements) {
                    compileStatement(s);
                }
            }
        } else {
            assert(0, "compileStatement: unhandled statement type: " ~ typeid(stmt).name);
        }
    }

    /// Compile pre/post increment/decrement (++i, i++, --i, i--)
    private void compileIncDec(UnaryExpression expr) {
        auto ident = cast(IdentifierExpression)expr.operand;
        if (!ident)
            throw new Exception("Increment/decrement requires identifier");

        auto info = ident.name in localVars;
        if (info is null)
            throw new Exception("Increment/decrement on unknown variable: " ~ ident.name);
        if (info.kind != VarKind.scalar)
            throw new Exception("Increment/decrement requires scalar variable");

        bool isInc = (expr.operator == UnaryExpression.Operator.PreIncrement
                   || expr.operator == UnaryExpression.Operator.PostIncrement);
        bool isPost = (expr.operator == UnaryExpression.Operator.PostIncrement
                    || expr.operator == UnaryExpression.Operator.PostDecrement);

        // Load old value, compute new = old ± 1, store back.
        // stencil_add_i32: w0 = w1 + w0.  Use +1 for inc, +(-1) for dec.
        gen.emitLoadLocal32(info.offset);                   // w0 = old
        gen.emitMoveX0ToX1();                               // x1 = old (preserved across add+store)
        gen.emitImm32(stencil_load_imm32, isInc ? 1 : -1); // w0 = ±1
        gen.emit(stencil_add_i32);                          // w0 = old ± 1
        gen.emitStoreLocal32(info.offset);                  // store new value

        if (isPost)
            gen.emit(stencil_move_arg1_to_result);          // x0 = x1 = old (return old)
        // else: x0 already has new value
    }

    /// Check if an expression contains a function call (which would clobber registers)
    private bool containsFunctionCall(Expression expr) {
        if (expr is null) return false;
        
        if (cast(CallExpression)expr) {
            // Check if it's a struct construction (not a real function call)
            if (auto call = cast(CallExpression)expr) {
                if (auto funcIdent = cast(IdentifierExpression)call.function_) {
                    auto symbol = symbolTable.lookupSymbol(funcIdent.name);
                    if (symbol && symbol.kind == SymbolKind.Type) {
                        return false;  // Struct construction, not a function call
                    }
                }
            }
            return true;
        }
        
        if (auto binary = cast(BinaryExpression)expr) {
            return containsFunctionCall(binary.left) || containsFunctionCall(binary.right);
        }
        if (auto unary = cast(UnaryExpression)expr) {
            return containsFunctionCall(unary.operand);
        }
        if (auto index = cast(IndexExpression)expr) {
            return containsFunctionCall(index.array) || containsFunctionCall(index.index);
        }
        if (auto member = cast(MemberExpression)expr) {
            return containsFunctionCall(member.object);
        }
        
        return false;
    }
    
    /// Check if a Type is f64 (double/float).
    private static bool isF64ElementType(Type t) {
        if (auto bt = cast(BasicType)t)
            return bt.kind == BasicType.Kind.Float64 || bt.kind == BasicType.Kind.Float32;
        return false;
    }

    /// Check if an expression produces an f64 value.
    private bool isF64Expression(Expression expr) {
        import std.variant : Variant;
        if (auto lit = cast(LiteralExpression)expr)
            return lit.value.type == typeid(double);
        if (auto idx = cast(IndexExpression)expr) {
            if (auto ident = cast(IdentifierExpression)idx.array)
                if (auto info = ident.name in localVars)
                    return isF64ElementType(info.elementType);
            return false;
        }
        if (auto bin = cast(BinaryExpression)expr)
            return isF64Expression(bin.left);
        if (auto unary = cast(UnaryExpression)expr)
            return isF64Expression(unary.operand);
        if (auto castExpr = cast(CastExpression)expr) {
            if (auto bt = cast(BasicType)castExpr.targetType)
                return bt.kind == BasicType.Kind.Float64 || bt.kind == BasicType.Kind.Float32;
            return false;
        }
        return false;
    }

    private void compileExpression(Expression expr) {
        import std.variant : Variant;
        log(3, "native: expr ", typeid(expr));
        if (auto lit = cast(LiteralExpression)expr) {
            // Handle different literal types via Variant
            if (lit.value.type == typeid(long)) {
                gen.emitImm32(stencil_load_imm32, cast(int)lit.value.get!long);
            } else if (lit.value.type == typeid(int)) {
                gen.emitImm32(stencil_load_imm32, lit.value.get!int);
            } else if (lit.value.type == typeid(bool)) {
                gen.emitImm32(stencil_load_imm32, lit.value.get!bool ? 1 : 0);
            } else if (lit.value.type == typeid(char)) {
                gen.emitImm32(stencil_load_imm32, cast(int)lit.value.get!char);
            } else if (lit.value.type == typeid(string)) {
                // String literal in expression context (e.g., as a call argument)
                // Allocate a temp slice on the local stack, populate it, return pointer
                string strVal = lit.value.get!string();
                size_t tempOffset = (nextLocalOffset + 7) & ~7;  // 8-byte align
                nextLocalOffset = tempOffset + sliceInfo.totalSize;
                assert(nextLocalOffset <= temps.tempBase(),
                    "Frame overflow in string literal: nextLocalOffset exceeds temp zone");
                compileStringLiteralInit(tempOffset, strVal);
                gen.emitStackAddress(tempOffset);
            } else if (lit.value.type == typeid(double)) {
                // Double literal: load 64-bit IEEE 754 bits into x0, then transfer to d0
                double val = lit.value.get!double();
                long bits = *cast(long*)&val;
                // Verify round-trip: bits back to double should equal val
                double check = *cast(double*)&bits;
                assert(check == val || (check != check && val != val),  // NaN != NaN
                       "double bit pattern round-trip failed");
                gen.emitLoadImm64(cast(ulong)bits);
                gen.emitMoveX0ToD0();
            } else {
                throw new Exception("Literal type not supported: " ~ lit.value.type.toString());
            }
        } else if (auto binOp = cast(BinaryExpression)expr) {
            // Lowered shift operators — emit the call instead of raw opcode
            if (binOp.loweredCall) {
                compileExpression(binOp.loweredCall);
                return;
            }

            // Short-circuit evaluation for && and ||
            if (binOp.operator == BinaryExpression.Operator.LogicalAnd) {
                // a && b: evaluate a; if 0, result=0; else evaluate b, normalize to 0/1
                compileExpression(binOp.left);
                auto skipRight = gen.newLabel();
                auto done = gen.newLabel();
                gen.emitBranchIfZero(skipRight);
                compileExpression(binOp.right);
                gen.emitMoveX0ToX1();
                gen.emitImm32(stencil_load_imm32, 0);
                gen.emit(stencil_ne_i32);
                gen.emitBranch(done);
                gen.bindLabel(skipRight);
                gen.emitImm32(stencil_load_imm32, 0);
                gen.bindLabel(done);
                return;
            }
            if (binOp.operator == BinaryExpression.Operator.LogicalOr) {
                // a || b: evaluate a; if non-zero, result=1; else evaluate b, normalize to 0/1
                compileExpression(binOp.left);
                auto evalRight = gen.newLabel();
                auto done = gen.newLabel();
                gen.emitBranchIfZero(evalRight);
                gen.emitImm32(stencil_load_imm32, 1);
                gen.emitBranch(done);
                gen.bindLabel(evalRight);
                compileExpression(binOp.right);
                gen.emitMoveX0ToX1();
                gen.emitImm32(stencil_load_imm32, 0);
                gen.emit(stencil_ne_i32);
                gen.bindLabel(done);
                return;
            }

            // Array/string concatenation: a ~ b
            if (binOp.operator == BinaryExpression.Operator.Concat) {
                compileArrayConcat(binOp);
                return;
            }

            // f64 floating-point path: computation in d0/d1
            if (isF64Expression(binOp.left)) {
                // Evaluate right → d0, save to temp
                compileExpression(binOp.right);
                auto mark = temps.save();
                size_t myTemp = temps.alloc(8);
                gen.emitStoreLocalF64(myTemp);
                // Evaluate left → d0
                compileExpression(binOp.left);
                // Load right into d1 (does not clobber d0)
                gen.emitLoadLocalF64ToD1(myTemp);
                temps.restore(mark);
                // Emit f64 operation
                switch (binOp.operator) {
                    case BinaryExpression.Operator.Add: gen.emit(stencil_add_f64); break;
                    case BinaryExpression.Operator.Subtract: gen.emit(stencil_sub_f64); break;
                    case BinaryExpression.Operator.Multiply: gen.emit(stencil_mul_f64); break;
                    case BinaryExpression.Operator.Divide: gen.emit(stencil_div_f64); break;
                    case BinaryExpression.Operator.Equal: gen.emit(stencil_eq_f64); break;
                    case BinaryExpression.Operator.NotEqual: gen.emit(stencil_ne_f64); break;
                    case BinaryExpression.Operator.Less: gen.emit(stencil_lt_f64); break;
                    case BinaryExpression.Operator.LessEqual: gen.emit(stencil_le_f64); break;
                    case BinaryExpression.Operator.Greater: gen.emit(stencil_gt_f64); break;
                    case BinaryExpression.Operator.GreaterEqual: gen.emit(stencil_ge_f64); break;
                    default:
                        throw new Exception("Float binary operator not supported in native backend");
                }
                return;
            }

            // Check if left operand might clobber x1 (function call, nested binary expr, index expr,
            // or member expr whose object evaluation uses x1 for address calculation)
            bool leftMightClobber = containsFunctionCall(binOp.left) ||
                                    cast(BinaryExpression)binOp.left !is null ||
                                    cast(IndexExpression)binOp.left !is null ||
                                    cast(MemberExpression)binOp.left !is null;

            // Compile right operand first (into x0)
            compileExpression(binOp.right);

            if (leftMightClobber) {
                // Save right result to temp slot (function calls clobber x0-x7)
                auto mark = temps.save();
                size_t myTempSlot = temps.alloc(8);
                gen.emitStoreLocal32(myTempSlot);
                // Compile left operand (into x0)
                compileExpression(binOp.left);
                // Now x0 = left result
                // Save left to x8 (safe since no more calls)
                gen.emitMoveX0ToX8();  // x8 = left
                // Load right from temp slot
                gen.emitLoadLocal32(myTempSlot);  // x0 = right
                gen.emitMoveX0ToX1();  // x1 = right
                // Restore left from x8
                gen.emitMoveX8ToX0();  // x0 = left
                temps.restore(mark);
            } else {
                gen.emitMoveX0ToX1();  // Move to x1
                // Compile left operand (into x0)
                compileExpression(binOp.left);
            }
            // Now x0=left, x1=right
            
            // Emit operation
            final switch (binOp.operator) {
                case BinaryExpression.Operator.Add:
                    gen.emit(stencil_add_i32);
                    break;
                case BinaryExpression.Operator.Subtract:
                    gen.emit(stencil_sub_i32);
                    break;
                case BinaryExpression.Operator.Multiply:
                    gen.emit(stencil_mul_i32);
                    break;
                case BinaryExpression.Operator.Divide:
                    emitCheckedDiv(binOp.location.filename ? binOp.location.filename : "",
                                   binOp.location.line, binOp.location.column);
                    break;
                case BinaryExpression.Operator.Modulo:
                    emitCheckedMod(binOp.location.filename ? binOp.location.filename : "",
                                   binOp.location.line, binOp.location.column);
                    break;
                case BinaryExpression.Operator.Equal:
                    gen.emit(stencil_eq_i32);
                    break;
                case BinaryExpression.Operator.NotEqual:
                    gen.emit(stencil_ne_i32);
                    break;
                case BinaryExpression.Operator.Less:
                    gen.emit(stencil_lt_i32);
                    break;
                case BinaryExpression.Operator.LessEqual:
                    gen.emit(stencil_le_i32);
                    break;
                case BinaryExpression.Operator.Greater:
                    gen.emit(stencil_gt_i32);
                    break;
                case BinaryExpression.Operator.GreaterEqual:
                    gen.emit(stencil_ge_i32);
                    break;
                case BinaryExpression.Operator.BitwiseAnd:
                    gen.emit(stencil_and_i32);
                    break;
                case BinaryExpression.Operator.BitwiseOr:
                    gen.emit(stencil_or_i32);
                    break;
                case BinaryExpression.Operator.BitwiseXor:
                    gen.emit(stencil_xor_i32);
                    break;
                case BinaryExpression.Operator.ShiftLeft:
                    assert(0, "ShiftLeft should be lowered to opShiftLeft call");
                case BinaryExpression.Operator.ShiftRight:
                    assert(0, "ShiftRight should be lowered to opShiftRight call");
                case BinaryExpression.Operator.UnsignedShiftRight:
                    assert(0, "UnsignedShiftRight should be lowered to opUnsignedShiftRight call");
                case BinaryExpression.Operator.LogicalAnd:
                    assert(0, "LogicalAnd should be handled by short-circuit above");
                case BinaryExpression.Operator.LogicalOr:
                    assert(0, "LogicalOr should be handled by short-circuit above");
                case BinaryExpression.Operator.Concat:
                    assert(0, "Concat should be handled by compileArrayConcat above");
            }
        } else if (auto unaryOp = cast(UnaryExpression)expr) {
            if (unaryOp.loweredCall) {
                compileExpression(unaryOp.loweredCall);
            } else if (unaryOp.operator == UnaryExpression.Operator.Minus && isF64Expression(unaryOp.operand)) {
                compileExpression(unaryOp.operand);
                gen.emit(stencil_neg_f64);
            } else if (unaryOp.operator == UnaryExpression.Operator.Minus) {
                compileExpression(unaryOp.operand);
                // 0 - x
                gen.emitMoveX0ToX1();
                gen.emitImm32(stencil_load_imm32, 0);
                gen.emit(stencil_sub_i32);
            } else if (unaryOp.operator == UnaryExpression.Operator.LogicalNot) {
                compileExpression(unaryOp.operand);
                // x == 0
                gen.emitMoveX0ToX1();
                gen.emitImm32(stencil_load_imm32, 0);
                gen.emit(stencil_eq_i32);
            } else if (unaryOp.operator == UnaryExpression.Operator.BitwiseNot) {
                compileExpression(unaryOp.operand);
                // ~x
                gen.emit(stencil_not_i32);
            } else if (unaryOp.operator == UnaryExpression.Operator.PreIncrement
                    || unaryOp.operator == UnaryExpression.Operator.PostIncrement
                    || unaryOp.operator == UnaryExpression.Operator.PreDecrement
                    || unaryOp.operator == UnaryExpression.Operator.PostDecrement) {
                compileIncDec(unaryOp);
            } else if (unaryOp.operator == UnaryExpression.Operator.Dereference) {
                // *ptr — dereference a pointer
                compileExpression(unaryOp.operand);
                // Result is pointer address in x0; load the pointed-to value
                if (auto pt = cast(PointerType)unaryOp.operand.type) {
                    auto pointeeSize = pt.pointeeType.size();
                    if (pointeeSize == 1)
                        gen.emitLoadByteFromPointer(0);
                    else if (!pt.pointeeType.isBasicType()) {
                        // Struct/aggregate: pointer value IS the address, no load needed
                    } else
                        gen.emitLoadFromPointer(0);
                } else {
                    gen.emitLoadFromPointer(0);
                }
            } else {
                assert(0, "Unsupported unary operator: " ~ to!string(unaryOp.operator));
            }
        } else if (auto ident = cast(IdentifierExpression)expr) {
            log(3, "native:   ident '", ident.name, "'");
            // Load variable from stack
            if (auto info = ident.name in localVars) {
                log(3, "native:     -> local (kind=", info.kind, ", offset=", info.offset, ")");
                // ObjC refs and raw pointers are 8-byte values — load full 64-bit
                if (info.isObjCRef || info.isRawPointer) {
                    gen.emitLoadPtr(info.offset);
                    return;
                }
                final switch (info.kind) {
                    case VarKind.class_:
                        // Class references: load the stored pointer
                        // Class locals: emit stack address
                        if (info.isReference)
                            gen.emitLoadPtr(info.offset);
                        else
                            gen.emitStackAddress(info.offset);
                        break;
                    case VarKind.struct_:
                    case VarKind.staticArray:
                    case VarKind.slice:
                    case VarKind.delegate_:
                        // Aggregate types: emit address (pointer) instead of loading value
                        gen.emitStackAddress(info.offset);
                        break;
                    case VarKind.scalar:
                        gen.emitLoadLocal32(info.offset);
                        break;
                }
            } else {
                // Check if it's a manifest constant
                auto symbol = symbolTable.lookupSymbol(ident.name);
                if (symbol && symbol.isConstant) {
                    if (auto manifest = cast(ManifestConstantDecl)symbol.declaration) {
                        log(3, "native:     -> manifest '", manifest.name, "'");
                        assert(manifest.ownModuleResolver !is null,
                            "Manifest '" ~ manifest.name ~ "' reached codegen without resolver stamp");
                        manifest.ensureEvaluated();

                        if (manifest.isStringType) {
                            // String literal: allocate temp slice and return pointer
                            size_t tempOffset = (nextLocalOffset + 7) & ~7;
                            nextLocalOffset = tempOffset + sliceInfo.totalSize;
                            compileStringLiteralInit(tempOffset, manifest.ctfeStringValue);
                            gen.emitStackAddress(tempOffset);
                        } else if (manifest.isFloatType) {
                            double val = manifest.ctfeFloatValue;
                            long bits = *cast(long*)&val;
                            gen.emitLoadImm64(cast(ulong)bits);
                            gen.emitMoveX0ToD0();
                        } else {
                            gen.emitImm32(stencil_load_imm32, cast(int)manifest.ctfeValue);
                        }
                        return;
                    }
                }

                if (auto currentAgg = currentMethodAggregate()) {
                    // In a method: check for implicit field access (field without 'this.')
                    auto field = currentAgg.getField(ident.name);
                    log(3, "native:     -> implicit field '", ident.name, "' in ", currentAgg.name,
                        " found=", field !is null,
                        field ? " offset=" : "", field ? to!string(field.offset) : "");
                    if (field) {
                        // Slice field: emit address (this_ptr + field.offset) — consumed by .length, [i], ~= etc.
                        if (auto arrType = cast(ArrayType)field.type) {
                            if (!arrType.isStaticArray) {
                                gen.emitLoadPtr(currentThisOffset);  // x0 = this ptr (64-bit)
                                if (field.offset > 0) {
                                    gen.emitMoveX0ToX1();
                                    gen.emitImm32(stencil_load_imm32, cast(int)field.offset);
                                    gen.emit(stencil_add_i64);  // x0 = this + field.offset
                                }
                                return;  // address of slice struct on stack
                            }
                        }
                        // Scalar/struct field: load value
                        gen.emitLoadPtr(currentThisOffset);  // x0 = this ptr (64-bit)
                        gen.emitLoadFromPointer(field.offset);  // x0 = this.field
                        return;
                    }
                    if (symbol && cast(VariableDecl)symbol.declaration)
                        throw new NativeCompileError(
                            "Cannot access module-level variable '" ~ ident.name ~ "' during CTFE",
                            ident.location);
                    throw new NativeCompileError("Unknown variable in native backend: " ~ ident.name, ident.location);
                } else {
                    if (symbol && cast(VariableDecl)symbol.declaration)
                        throw new NativeCompileError(
                            "Cannot access module-level variable '" ~ ident.name ~ "' during CTFE",
                            ident.location);
                    throw new NativeCompileError("Unknown variable in native backend: " ~ ident.name, ident.location);
                }
            }
        } else if (auto assign = cast(AssignmentExpression)expr) {
            // Check for index assignment (arr[i] = value)
            if (auto indexExpr = cast(IndexExpression)assign.left) {
                if (assign.operator == AssignmentExpression.Operator.Assign) {
                    emitIndexAssignment(indexExpr, assign.right);
                    return;
                } else {
                    throw new Exception("Compound index assignment not yet supported in native backend");
                }
            }

            // Check for member expression assignment (c.value = 10, s.data ~= v)
            if (auto member = cast(MemberExpression)assign.left) {
                // Handle slice field append: s.data ~= value
                if (assign.operator == AssignmentExpression.Operator.ConcatAssign) {
                    if (auto objIdent = cast(IdentifierExpression)member.object) {
                        if (auto structInfo = objIdent.name in localVars) {
                            AggregateDecl aggDecl = structInfo.isStruct ?
                                cast(AggregateDecl)structInfo.structDecl :
                                (structInfo.isClass ? cast(AggregateDecl)structInfo.classDecl : null);
                            if (aggDecl) {
                                auto sField = aggDecl.getField(member.memberName);
                                if (sField) {
                                    if (auto arrType = cast(ArrayType)sField.type) {
                                        if (!arrType.isStaticArray) {
                                            compileSliceFieldAppendLocal(structInfo.offset, sField.offset, assign.right, arrType);
                                            return;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                compileMemberAssignment(member, assign);
                return;
            }

            auto targetIdent = cast(IdentifierExpression)assign.left;
            if (targetIdent is null) {
                throw new NativeCompileError("Assignment to non-identifier not yet supported in native backend", assign.location);
            }
            
            auto info = targetIdent.name in localVars;
            if (info is null) {
                // In a method: check for implicit field assignment
                if (auto currentAgg = currentMethodAggregate()) {
                    auto field = currentAgg.getField(targetIdent.name);
                    log(3, "native: assign implicit field '", targetIdent.name, "' in ", currentAgg.name, " found=", field !is null);
                    if (field) {
                        // ConcatAssign on implicit slice field: data ~= value
                        if (assign.operator == AssignmentExpression.Operator.ConcatAssign) {
                            if (auto arrType = cast(ArrayType)field.type) {
                                if (!arrType.isStaticArray) {
                                    compileSliceFieldAppend(field.offset, assign.right, arrType);
                                    return;
                                }
                            }
                        }
                        if (assign.operator == AssignmentExpression.Operator.Assign) {
                            compileExpression(assign.right);  // x0 = value
                            gen.emitMoveX0ToX9();             // x9 = value
                            gen.emitLoadPtr(currentThisOffset);  // x0 = this ptr
                            gen.emitStoreToPointerFromX9(field.offset);  // this.field = x9
                            return;
                        }
                    }
                }
                auto symbol = symbolTable.lookupSymbol(targetIdent.name);
                if (symbol && cast(VariableDecl)symbol.declaration)
                    throw new NativeCompileError(
                        "Cannot access module-level variable '" ~ targetIdent.name ~ "' during CTFE",
                        targetIdent.location);
                throw new NativeCompileError("Unknown variable in native backend: " ~ targetIdent.name, targetIdent.location);
            }

            // Handle slice append specially (~=)
            if (assign.operator == AssignmentExpression.Operator.ConcatAssign) {
                if (info.isSlice) {
                    compileSliceAppend(info.offset, assign.right, info.elemSize, isF64ElementType(info.elementType));
                    return;
                } else {
                    throw new Exception("~= only supported on slice types");
                }
            }
            
            if (assign.loweredCall) {
                // Lowered shift compound assignment: emit call, store result
                compileExpression(assign.loweredCall);
                if (info.isRawPointer || info.isObjCRef)
                    gen.emitStorePtr(info.offset);
                else
                    gen.emitStoreLocal32(info.offset);
            } else if (assign.operator == AssignmentExpression.Operator.Assign) {
                // Simple assignment: x = expr
                compileExpression(assign.right);
                if (info.isRawPointer || info.isObjCRef)
                    gen.emitStorePtr(info.offset);
                else
                    gen.emitStoreLocal32(info.offset);
            } else {
                // Compound assignment: x op= expr
                // First compile right side to x0
                compileExpression(assign.right);
                gen.emitMoveX0ToX1();  // x1 = right value

                // Load current value to x0
                if (info.isRawPointer || info.isObjCRef)
                    gen.emitLoadPtr(info.offset);
                else
                    gen.emitLoadLocal32(info.offset);
                // Now x0 = current (left), x1 = right
                
                // Apply operation based on operator
                switch (assign.operator) {
                    case AssignmentExpression.Operator.AddAssign:
                        gen.emit(stencil_add_i32);
                        break;
                    case AssignmentExpression.Operator.SubtractAssign:
                        gen.emit(stencil_sub_i32);
                        break;
                    case AssignmentExpression.Operator.MultiplyAssign:
                        gen.emit(stencil_mul_i32);
                        break;
                    case AssignmentExpression.Operator.DivideAssign:
                        emitCheckedDiv(assign.location.filename ? assign.location.filename : "",
                                       assign.location.line, assign.location.column);
                        break;
                    case AssignmentExpression.Operator.ModuloAssign:
                        emitCheckedMod(assign.location.filename ? assign.location.filename : "",
                                       assign.location.line, assign.location.column);
                        break;
                    case AssignmentExpression.Operator.AndAssign:
                        gen.emit(stencil_and_i32);
                        break;
                    case AssignmentExpression.Operator.OrAssign:
                        gen.emit(stencil_or_i32);
                        break;
                    case AssignmentExpression.Operator.XorAssign:
                        gen.emit(stencil_xor_i32);
                        break;
                    case AssignmentExpression.Operator.ShiftLeftAssign:
                        assert(0, "<<= should be lowered to opShiftLeft call");
                    case AssignmentExpression.Operator.ShiftRightAssign:
                        assert(0, ">>= should be lowered to opShiftRight call");
                    case AssignmentExpression.Operator.ConcatAssign:
                        // Handled specially above for slices
                        throw new Exception("~= on non-slice not supported");
                    default:
                        break;
                }
                
                // Store result back
                if (info.isRawPointer || info.isObjCRef)
                    gen.emitStorePtr(info.offset);
                else
                    gen.emitStoreLocal32(info.offset);
            }
            // Result of assignment is the assigned value (already in x0)
        } else if (auto call = cast(CallExpression)expr) {
            log(3, "native: call ", cast(IdentifierExpression)call.function_ ? (cast(IdentifierExpression)call.function_).name : cast(MemberExpression)call.function_ ? (cast(MemberExpression)call.function_).memberName : "?");
            // Check if this is struct construction
            if (auto funcIdent = cast(IdentifierExpression)call.function_) {
                auto symbol = symbolTable.lookupSymbol(funcIdent.name);
                if (symbol && symbol.kind == SymbolKind.Type) {
                    if (auto structDecl = symbol.type.asStruct()) {
                        // Struct construction: allocate space and init fields
                        compileStructConstruction(structDecl, call.arguments);
                        return;
                    }
                }
                
                // Milestone 89: Handle __writeln - lower to typed write calls
                if (funcIdent.name == "__writeln") {
                    compileWriteln(call.arguments);
                    return;
                }

                // Compiler intrinsics — emit raw opcodes, no function call
                if (funcIdent.name.length > 12 && funcIdent.name[0..12] == "__intrinsic_") {
                    compileIntrinsicCall(funcIdent.name, call.arguments);
                    return;
                }

                // Resolve to mangled name for function label lookup
                string callName = resolveMangledName(funcIdent, call);

                // Check if this is a call to a known function
                if (auto labelPtr = callName in functionLabels) {
                    // Check if callee needs arena (shifts user args by 1 register)
                    bool calleeNeedsArena = false;
                    if (auto calleeDecl = callName in functionDecls) {
                        calleeNeedsArena = (*calleeDecl).needsArena;
                    }
                    int arenaShift = calleeNeedsArena ? 1 : 0;

                    if (call.arguments.length + arenaShift > 4) {
                        throw new Exception("Native backend: more than 4 arguments not yet supported");
                    }

                    // Check if any argument contains a function call that would clobber registers
                    bool hasNestedCalls = false;
                    foreach (arg; call.arguments) {
                        if (containsCall(arg)) {
                            hasNestedCalls = true;
                            break;
                        }
                    }

                    if (hasNestedCalls && call.arguments.length > 1) {
                        // Save arguments to temp slots, then load into registers
                        // This prevents register clobbering from nested calls
                        auto mark = temps.save();
                        size_t[] argSlots;
                        foreach (i, arg; call.arguments) {
                            compileExpression(arg);
                            size_t slot = temps.alloc(8);
                            gen.emitStorePtr(slot);
                            argSlots ~= slot;
                        }
                        // Load from temp slots into argument registers (reverse order!)
                        // Arena shifts user args: x0 -> x(0+shift), etc.
                        for (long i = cast(long)argSlots.length - 1; i >= 0; i--) {
                            gen.emitLoadPtr(argSlots[cast(size_t)i]);
                            switch (cast(int)i + arenaShift) {
                                case 0: break;  // already in x0
                                case 1: gen.emitMoveX0ToX1(); break;
                                case 2: gen.emitMoveX0ToX2(); break;
                                case 3: gen.emitMoveX0ToX3(); break;
                                default: assert(0, "argument register > 3");
                            }
                        }
                        temps.restore(mark);
                    } else {
                        // No nested calls - use the faster direct approach
                        // Compile arguments in reverse order into their target registers
                        for (long i = cast(long)call.arguments.length - 1; i >= 0; i--) {
                            compileExpression(call.arguments[i]);
                            // Move x0 to target register (shifted by arena)
                            switch (cast(int)i + arenaShift) {
                                case 0: break;  // already in x0
                                case 1: gen.emitMoveX0ToX1(); break;
                                case 2: gen.emitMoveX0ToX2(); break;
                                case 3: gen.emitMoveX0ToX3(); break;
                                default: assert(0, "argument register > 3");
                            }
                        }
                    }

                    // Load arena into x0 if callee needs it
                    if (calleeNeedsArena) {
                        gen.emitLoadPtr(currentFunctionArenaOffset);
                    }

                    // Emit the call (BL instruction)
                    gen.emitCall(*labelPtr);
                    // Check for exception after call (preserves return value in x0)
                    emitNativeExceptionCheckWithValue();
                    // Result is in x0
                    return;
                }
                
                // Milestone 88/90: Check if this is a host function call
                ulong hostSlot = hostFunctions.getFunctionSlotAddress(funcIdent.name);
                if (hostSlot != 0) {
                    if (call.arguments.length > 3) {
                        throw new Exception("Native backend: host functions support max 3 arguments (x0 reserved for context)");
                    }
                    
                    // Compile arguments in reverse order into x0-x2
                    // emitHostCall will shift them to x1-x3 and inject context in x0
                    for (long i = cast(long)call.arguments.length - 1; i >= 0; i--) {
                        compileExpression(call.arguments[i]);
                        switch (i) {
                            case 0: break;  // already in x0
                            case 1: gen.emitMoveX0ToX1(); break;
                            case 2: gen.emitMoveX0ToX2(); break;
                            default: break;
                        }
                    }
                    
                    // Emit host call with context injection
                    ulong contextSlot = hostFunctions.getContextSlotAddress();
                    gen.emitHostCall(hostSlot, contextSlot);
                    // Result is in x0
                    return;
                }

                // Object-mode extern(C): emit BL with relocation (linker resolves)
                if (objectMode && funcIdent.name in objectExternFunctions) {
                    emitCCallArgs(call.arguments);
                    emitObjectExternalCall(funcIdent.name);
                    return;
                }

                // Check if this is an FFI call (extern(C) import resolved via dlsym)
                if (auto ffiSlot = funcIdent.name in ffiSlots) {
                    emitCCallArgs(call.arguments);

                    // Call through the function pointer slot (no context injection)
                    gen.emitIndirectCall(*ffiSlot);
                    // Result is in x0
                    return;
                }
            }
            // Check for method call: obj.method()
            if (auto memberCall = cast(MemberExpression)call.function_) {
                if (call.isUFCS) {
                    // UFCS: obj.func(args...) → func(obj, args...)
                    emitUFCSCall(memberCall, call.arguments);
                    return;
                }
                emitMethodCall(memberCall, call.arguments);
                return;
            }
            throw new Exception("Function calls not yet supported in native backend: " ~
                (cast(IdentifierExpression)call.function_ ? (cast(IdentifierExpression)call.function_).name : "unknown"));
        } else if (auto member = cast(MemberExpression)expr) {
            // Check for slice.length / slice.ptr first
            if (member.memberName == "length" || member.memberName == "ptr") {
                if (auto ident = cast(IdentifierExpression)member.object) {
                    if (auto varInfo = ident.name in localVars) {
                        if (varInfo.isSlice) {
                            if (member.memberName == "length")
                                gen.emitLoadLocal32(varInfo.offset + sliceInfo.lengthOffset);
                            else
                                gen.emitLoadPtr(varInfo.offset);  // ptr is at offset 0 (64-bit)
                            return;
                        }
                    }
                }
            }

            // Member access on indexed slice elements (e.g., arr[i].length where arr is T[][])
            if (auto indexExpr = cast(IndexExpression)member.object) {
                if (auto ident = cast(IdentifierExpression)indexExpr.array) {
                    if (auto info = ident.name in localVars) {
                        if (info.isSlice) {
                            if (auto elemArr = cast(ArrayType)info.elementType) {
                                if (!elemArr.isStaticArray) {
                                    // Element is a dynamic array — compile index to get element address
                                    compileExpression(indexExpr);  // x0 = address of inner slice struct

                                    // Load the requested field from the slice struct at x0
                                    if (member.memberName == "ptr") {
                                        gen.emit(stencil_load_i64);  // 64-bit pointer at offset 0
                                        return;
                                    } else if (member.memberName == "length") {
                                        gen.emitLoadFromPointer(sliceInfo.lengthOffset);
                                        return;
                                    } else if (member.memberName == "capacity") {
                                        gen.emitLoadFromPointer(sliceInfo.capacityOffset);
                                        return;
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Chained member on slice field: s.data.length, s.data.ptr, s.data.capacity
            if (auto innerMember = cast(MemberExpression)member.object) {
                AggregateDecl innerAggDecl = getAggregateDeclFromExpr(innerMember.object);
                if (innerAggDecl) {
                    auto innerField = innerAggDecl.getField(innerMember.memberName);
                    if (innerField) {
                        if (auto arrType = cast(ArrayType)innerField.type) {
                            if (!arrType.isStaticArray) {
                                // Compile inner member to get slice address
                                compileExpression(innerMember);  // x0 = address of slice struct
                                if (member.memberName == "length") {
                                    gen.emitLoadFromPointer(sliceInfo.lengthOffset);
                                } else if (member.memberName == "ptr") {
                                    gen.emit(stencil_load_i64);  // 64-bit pointer at offset 0
                                } else if (member.memberName == "capacity") {
                                    gen.emitLoadFromPointer(sliceInfo.capacityOffset);
                                } else {
                                    throw new Exception("Slice field has no member '" ~ member.memberName ~ "'");
                                }
                                return;
                            }
                        }
                    }
                }
            }

            // Implicit field access in method: data.length, data.ptr, data.capacity
            if (auto currentAgg = currentMethodAggregate()) {
                if (auto ident = cast(IdentifierExpression)member.object) {
                    if ((ident.name in localVars) is null) {
                        auto field = currentAgg.getField(ident.name);
                        if (field) {
                            if (auto arrType = cast(ArrayType)field.type) {
                                if (!arrType.isStaticArray) {
                                    // Emit address of slice struct via this pointer
                                    gen.emitLoadPtr(currentThisOffset);
                                    if (field.offset > 0) {
                                        gen.emitMoveX0ToX1();
                                        gen.emitImm32(stencil_load_imm32, cast(int)field.offset);
                                        gen.emit(stencil_add_i64);
                                    }
                                    // Now x0 = address of slice struct
                                    if (member.memberName == "length") {
                                        gen.emitLoadFromPointer(sliceInfo.lengthOffset);
                                    } else if (member.memberName == "ptr") {
                                        gen.emit(stencil_load_i64);
                                    } else if (member.memberName == "capacity") {
                                        gen.emitLoadFromPointer(sliceInfo.capacityOffset);
                                    } else {
                                        throw new Exception("Slice field has no member '" ~ member.memberName ~ "'");
                                    }
                                    return;
                                }
                            }
                        }
                    }
                }
            }

            // String literal .ptr / .length: "hello\0".ptr → pointer to string data
            if (member.memberName == "ptr" || member.memberName == "length") {
                if (auto litExpr = cast(LiteralExpression)member.object) {
                    if (litExpr.value.peek!string() !is null) {
                        string strVal = litExpr.value.get!string();
                        if (member.memberName == "ptr") {
                            emitStringLoad(strVal);
                            return;
                        } else {
                            // .length
                            gen.emitLoadImm(cast(int)strVal.length);
                            return;
                        }
                    }
                }
            }

            // Generic .ptr/.length/.capacity on any expression producing a dynamic array
            if (member.memberName == "ptr" || member.memberName == "length" || member.memberName == "capacity") {
                if (member.object.type !is null) {
                    auto objType = member.object.type.resolve();
                    if (auto arrType = cast(ArrayType)objType) {
                        if (!arrType.isStaticArray) {
                            compileExpression(member.object);  // x0 = address of slice struct
                            if (member.memberName == "ptr")
                                gen.emit(stencil_load_i64);  // 64-bit pointer at offset 0
                            else if (member.memberName == "length")
                                gen.emitLoadFromPointer(sliceInfo.lengthOffset);
                            else
                                gen.emitLoadFromPointer(sliceInfo.capacityOffset);
                            return;
                        }
                    }
                }
            }

            // Field access: obj.field (for structs and classes)
            AggregateDecl aggregateDecl = getAggregateDeclFromExpr(member.object);
            if (aggregateDecl is null) {
                throw new Exception("Cannot determine struct/class type for member access: " ~ member.memberName);
            }

            auto field = aggregateDecl.getField(member.memberName);
            if (field is null) {
                throw new Exception("Unknown field '" ~ member.memberName ~ "' on " ~ aggregateDecl.name);
            }

            // For local struct/class variables, load field
            if (auto ident = cast(IdentifierExpression)member.object) {
                if (auto varInfo = ident.name in localVars) {
                    if (varInfo.isReference) {
                        // Reference (class param / this): dereference pointer, then access field
                        gen.emitLoadPtr(varInfo.offset);  // x0 = pointer to instance
                        if (field.type.isAggregate()) {
                            if (field.offset > 0) {
                                gen.emitMoveX0ToX1();
                                gen.emitImm32(stencil_load_imm32, cast(int)field.offset);
                                gen.emit(stencil_add_i64);
                            }
                        } else {
                            gen.emitLoadFromPointer(field.offset);
                        }
                    } else {
                        // Direct instance on stack
                        size_t totalOffset = varInfo.offset + field.offset;
                        if (field.type.isAggregate()) {
                            gen.emitStackAddress(totalOffset);
                        } else {
                            gen.emitLoadLocal32(totalOffset);
                        }
                    }
                    return;
                }
            }
            
            // For other expressions (e.g., nested access), compile to get pointer
            compileExpression(member.object);
            // x0 now has pointer to struct
            size_t fieldOffset = field.offset;
            // Aggregate fields: compute address (for further nested access)
            // Scalar fields: load the value
            if (field.type.isAggregate()) {
                // Add offset to pointer: x0 = x0 + fieldOffset
                if (fieldOffset > 0) {
                    gen.emitMoveX0ToX1();
                    gen.emitImm32(stencil_load_imm32, cast(int)fieldOffset);
                    gen.emit(stencil_add_i64);  // 64-bit ptr arithmetic
                }
                // x0 now has address of nested aggregate
            } else {
                gen.emitLoadFromPointer(fieldOffset);
            }
        } else if (auto arrLit = cast(ArrayLiteralExpression)expr) {
            // Array literal: [1, 2, 3]
            // Allocate space for data + slice struct
            uint elemCount = cast(uint)arrLit.elements.length;
            uint dataSize = elemCount * 4;  // 4 bytes per int element
            const sliceSize = sliceInfo.totalSize;  // ptr, length, capacity
            
            size_t dataOffset = nextLocalOffset;
            nextLocalOffset += dataSize;
            size_t sliceOffset = (nextLocalOffset + 7) & ~7;  // 8-byte align for 64-bit ptr field
            nextLocalOffset = sliceOffset + sliceSize;
            assert(nextLocalOffset <= temps.tempBase(),
                "Frame overflow in array literal: nextLocalOffset exceeds temp zone");

            // Initialize data elements
            foreach (i, elem; arrLit.elements) {
                compileExpression(elem);
                gen.emitStoreLocal32(dataOffset + i * 4);
            }
            
            // Initialize slice struct
            // ptr = sp + dataOffset
            gen.emitLoadStackPointer();
            gen.emitMoveX0ToX1();
            gen.emitImm32(stencil_load_imm32, cast(int)dataOffset);
            gen.emit(stencil_add_i64);  // 64-bit ptr arithmetic
            gen.emitStorePtr(sliceOffset);  // store 64-bit ptr

            // length = elemCount
            gen.emitImm32(stencil_load_imm32, cast(int)elemCount);
            gen.emitStoreLocal32(sliceOffset + sliceInfo.lengthOffset);  // store length

            // capacity = elemCount
            gen.emitImm32(stencil_load_imm32, cast(int)elemCount);
            gen.emitStoreLocal32(sliceOffset + sliceInfo.capacityOffset);  // store capacity

            // Leave pointer to slice struct in x0
            gen.emitLoadStackPointer();
            gen.emitMoveX0ToX1();
            gen.emitImm32(stencil_load_imm32, cast(int)sliceOffset);
            gen.emit(stencil_add_i64);  // 64-bit ptr arithmetic
            
        } else if (auto indexExpr = cast(IndexExpression)expr) {
            // Array/slice indexing: arr[i]
            if (auto ident = cast(IdentifierExpression)indexExpr.array) {
                if (auto info = ident.name in localVars) {
                    final switch (info.kind) {
                        case VarKind.staticArray:
                            // Static array: elements stored inline at offset
                            uint saElemSz = info.staticArrayElemSize;
                            bool saIsFloat = isF64ElementType(info.elementType);
                            // For constant index, load directly (scalars only)
                            if (saElemSz <= 4 && !saIsFloat) {
                                if (auto indexLit = cast(LiteralExpression)indexExpr.index) {
                                    if (indexLit.value.type == typeid(long)) {
                                        uint idx = cast(uint)indexLit.value.get!long();
                                        gen.emitLoadLocal32(info.offset + idx * saElemSz);
                                        return;
                                    }
                                }
                            }
                            // For dynamic index (or aggregate elements), compute address
                            compileExpression(indexExpr.index);
                            gen.emitMoveX0ToX1();  // x1 = index
                            gen.emitImm32(stencil_load_imm32, saElemSz);
                            gen.emit(stencil_mul_i32);  // x0 = index * elemSize
                            gen.emitMoveX0ToX1();  // x1 = byte offset
                            gen.emitStackAddress(info.offset);  // x0 = base address
                            gen.emit(stencil_add_i64);  // x0 = element address (64-bit ptr)
                            // Load value from computed address
                            if (saIsFloat)
                                gen.emit(stencil_load_f64);  // LDR d0, [x0]
                            else if (saElemSz <= 4)
                                gen.emitLoadFromPointer(0);
                            return;

                        case VarKind.slice:
                            // Dynamic array (slice): { ptr: i64, length: i32, capacity: i32 }
                            bool slIsFloat = isF64ElementType(info.elementType);
                            assert(!slIsFloat || info.elemSize == 8,
                                   "f64 slice must have elemSize 8");
                            assert(info.offset % 8 == 0,
                                   "slice offset not 8-byte aligned");
                            compileExpression(indexExpr.index);
                            // x0 = index

                            // Bounds check: 0 <= index < length
                            emitBoundsCheck(info.offset,
                                            indexExpr.location.filename ? indexExpr.location.filename : "",
                                            indexExpr.location.line, indexExpr.location.column);
                            // x0 still = index

                            // Compute index * elemSize
                            gen.emitMoveX0ToX1();  // x1 = index
                            gen.emitImm32(stencil_load_imm32, info.elemSize);
                            gen.emit(stencil_mul_i32);  // x0 = index * elemSize
                            gen.emitMoveX0ToX1();  // x1 = byte offset

                            // Load 64-bit ptr from slice struct (offset 0)
                            gen.emitLoadPtr(info.offset);  // x0 = ptr (64-bit!)

                            // Compute address: ptr + byte offset
                            gen.emit(stencil_add_i64);  // 64-bit ptr arithmetic

                            // Load value from computed address
                            if (slIsFloat) {
                                gen.emit(stencil_load_f64);  // LDR d0, [x0]
                            } else if (info.elemSize <= 4) {
                                if (info.elemSize == 1)
                                    gen.emitLoadByteFromPointer(0);
                                else
                                    gen.emitLoadFromPointer(0);
                            }
                            return;

                        case VarKind.struct_:
                            assert(0, "Cannot index struct variable: " ~ ident.name);
                        case VarKind.class_:
                            assert(0, "Cannot index class variable: " ~ ident.name);
                        case VarKind.delegate_:
                            assert(0, "Cannot index delegate variable: " ~ ident.name);
                        case VarKind.scalar:
                            assert(0, "Cannot index scalar variable: " ~ ident.name);
                    }
                }
            }
            // Handle member expression as array source: s.data[i]
            if (auto memberExpr = cast(MemberExpression)indexExpr.array) {
                AggregateDecl mAggDecl = getAggregateDeclFromExpr(memberExpr.object);
                if (mAggDecl) {
                    auto mField = mAggDecl.getField(memberExpr.memberName);
                    if (mField) {
                        if (auto arrType = cast(ArrayType)mField.type) {
                            if (!arrType.isStaticArray) {
                                import codegen.type_marshal : TypeReader;
                                uint elemSize = TypeReader.forNative().elementSizeOf(arrType.elementType);
                                auto mark = temps.save();
                                size_t ptrTemp = temps.alloc(8);
                                // Get slice address, load ptr, save to temp
                                compileExpression(memberExpr);  // x0 = address of slice struct
                                gen.emit(stencil_load_i64);  // x0 = slice.ptr (64-bit)
                                gen.emitStorePtr(ptrTemp);
                                // Compute index * elemSize
                                compileExpression(indexExpr.index);  // x0 = index
                                gen.emitMoveX0ToX1();
                                gen.emitImm32(stencil_load_imm32, elemSize);
                                gen.emit(stencil_mul_i32);  // x0 = index * elemSize
                                gen.emitMoveX0ToX1();  // x1 = byte offset
                                // Load ptr from temp
                                gen.emitLoadPtr(ptrTemp);  // x0 = ptr
                                gen.emit(stencil_add_i64);  // x0 = ptr + byte_offset
                                // Load value for scalar elements
                                bool isFloat = isF64ElementType(arrType.elementType);
                                if (isFloat)
                                    gen.emit(stencil_load_f64);
                                else if (elemSize <= 4) {
                                    if (elemSize == 1)
                                        gen.emitLoadByteFromPointer(0);
                                    else
                                        gen.emitLoadFromPointer(0);
                                }
                                temps.restore(mark);
                                return;
                            }
                        }
                    }
                }
            }
            // Implicit field access in method: data[i] where data is a slice field
            if (auto currentAgg = currentMethodAggregate()) {
                if (auto ident2 = cast(IdentifierExpression)indexExpr.array) {
                    if ((ident2.name in localVars) is null) {
                        auto iField = currentAgg.getField(ident2.name);
                        if (iField) {
                            if (auto arrType = cast(ArrayType)iField.type) {
                                if (!arrType.isStaticArray) {
                                    import codegen.type_marshal : TypeReader;
                                    uint elemSize = TypeReader.forNative().elementSizeOf(arrType.elementType);
                                    auto mark = temps.save();
                                    size_t ptrTemp = temps.alloc(8);
                                    // Load slice.ptr from this_ptr + field.offset, save to temp
                                    gen.emitLoadPtr(currentThisOffset);  // x0 = this ptr
                                    if (iField.offset > 0) {
                                        gen.emitMoveX0ToX1();
                                        gen.emitImm32(stencil_load_imm32, cast(int)iField.offset);
                                        gen.emit(stencil_add_i64);
                                    }
                                    gen.emit(stencil_load_i64);  // x0 = slice.ptr
                                    gen.emitStorePtr(ptrTemp);
                                    // Compute index * elemSize
                                    compileExpression(indexExpr.index);  // x0 = index
                                    gen.emitMoveX0ToX1();
                                    gen.emitImm32(stencil_load_imm32, elemSize);
                                    gen.emit(stencil_mul_i32);  // x0 = index * elemSize
                                    gen.emitMoveX0ToX1();  // x1 = byte offset
                                    // Load ptr from temp
                                    gen.emitLoadPtr(ptrTemp);  // x0 = ptr
                                    gen.emit(stencil_add_i64);  // x0 = ptr + byte_offset
                                    // Load value for scalar elements
                                    bool isFloat = isF64ElementType(arrType.elementType);
                                    if (isFloat)
                                        gen.emit(stencil_load_f64);
                                    else if (elemSize <= 4) {
                                        if (elemSize == 1)
                                            gen.emitLoadByteFromPointer(0);
                                        else
                                            gen.emitLoadFromPointer(0);
                                    }
                                    temps.restore(mark);
                                    return;
                                }
                            }
                        }
                    }
                }
            }
            throw new Exception("Array indexing only supported for local variables");
        } else if (auto castExpr = cast(CastExpression)expr) {
            // Check for f64 → int conversion
            if (auto targetBt = cast(BasicType)castExpr.targetType) {
                bool targetIsInt = targetBt.kind != BasicType.Kind.Float64 &&
                                   targetBt.kind != BasicType.Kind.Float32;
                if (targetIsInt && isF64Expression(castExpr.expression)) {
                    assert(targetBt.kind == BasicType.Kind.Int32 ||
                           targetBt.kind == BasicType.Kind.UInt32 ||
                           targetBt.kind == BasicType.Kind.Int64 ||
                           targetBt.kind == BasicType.Kind.UInt64,
                           "f64→int cast: unexpected target type");
                    compileExpression(castExpr.expression);
                    gen.emit(stencil_f64_to_i32);  // FCVTZS w0, d0
                    return;
                }
            }
            // Most casts are no-ops at native level (everything is 32/64-bit)
            // Just compile the inner expression
            // Note: class→interface casts would need special handling when classes are supported
            compileExpression(castExpr.expression);
        } else if (auto sliceExpr = cast(SliceExpression)expr) {
            // Slice expression: source[start..end]
            // Create a temp slice struct on the stack and return its address
            auto sourceIdent = cast(IdentifierExpression)sliceExpr.array;
            if (!sourceIdent)
                throw new Exception("Complex slice source not supported in native backend");

            auto info = sourceIdent.name in localVars;
            if (info is null || (!info.isSlice && !info.isStaticArray))
                throw new Exception("Can only slice array-like variables in native backend");

            uint elemSize = info.elemSize;
            size_t tempOffset = (nextLocalOffset + 7) & ~7;  // 8-byte align for 64-bit ptr store
            nextLocalOffset = tempOffset + sliceInfo.totalSize;
            assert(nextLocalOffset <= temps.tempBase(),
                "Frame overflow in slice expression: nextLocalOffset exceeds temp zone");

            // Compute new ptr = base + start * elemSize
            if (info.isSlice) {
                gen.emitLoadPtr(info.offset);  // load 64-bit ptr from slice struct
            } else {
                gen.emitStackAddress(info.offset);  // static array: stack address IS data
            }
            gen.emitMoveX0ToX9();  // x9 = source.ptr

            // Compute start * elemSize
            compileExpression(sliceExpr.start);
            gen.emitMoveX0ToX1();  // x1 = start
            gen.emitImm32(stencil_load_imm32, elemSize);
            gen.emit(stencil_mul_i32);  // x0 = start * elemSize

            // ptr + start * elemSize (64-bit add: x9 + x0)
            gen.emitMoveX0ToX1();  // x1 = byte offset
            gen.emitMoveX9ToX0();  // x0 = source.ptr
            gen.emit(stencil_add_i64);  // x0 = new ptr (64-bit)
            gen.emitStorePtr(tempOffset);  // store 64-bit ptr

            // Compute length = end - start
            compileExpression(sliceExpr.end);
            gen.emitMoveX0ToX1();  // x1 = end
            compileExpression(sliceExpr.start);
            // x0 = start, x1 = end → need end - start
            // Swap: we need x0=end, x1=start
            gen.emitMoveX0ToX9();  // x9 = start
            gen.emitMoveX1ToX0();  // x0 = end
            gen.emitMoveX9ToX1();  // x1 = start
            gen.emit(stencil_sub_i32);  // x0 = end - start
            gen.emitStoreLocal32(tempOffset + sliceInfo.lengthOffset);

            // capacity = length (reload)
            compileExpression(sliceExpr.end);
            gen.emitMoveX0ToX1();
            compileExpression(sliceExpr.start);
            gen.emitMoveX0ToX9();
            gen.emitMoveX1ToX0();
            gen.emitMoveX9ToX1();
            gen.emit(stencil_sub_i32);
            gen.emitStoreLocal32(tempOffset + sliceInfo.capacityOffset);

            // Return address of temp slice struct
            gen.emitStackAddress(tempOffset);
        } else if (auto traits = cast(TraitsExpression)expr) {
            traits.evaluate();
            gen.emitImm32(stencil_load_imm32, traits.boolResult ? 1 : 0);
        } else if (auto isExpr = cast(IsExpression)expr) {
            gen.emitImm32(stencil_load_imm32, isExpr.boolResult ? 1 : 0);
        } else if (auto tmplInst = cast(TemplateInstantiationExpression)expr) {
            // Struct template construction: Pair!(int, int)(10, 20)
            if (tmplInst.resolvedStructInstantiation) {
                compileStructConstruction(tmplInst.resolvedStructInstantiation, tmplInst.callArguments);
                return;
            }

            // Template instantiation call — emit like a regular call using the mangled name
            auto inst = tmplInst.resolvedInstantiation;
            if (!inst)
                throw new Exception("Template instantiation not resolved: " ~ tmplInst.templateName);

            string instCallName = getMangledName(inst);
            auto labelPtr = instCallName in functionLabels;
            if (!labelPtr)
                throw new Exception("Template instantiation label not found: " ~ instCallName);

            // Check if callee needs arena
            bool calleeNeedsArena = inst.needsArena;
            int arenaShift = calleeNeedsArena ? 1 : 0;

            // Compile arguments into registers (shifted by arena)
            for (long i = cast(long)tmplInst.callArguments.length - 1; i >= 0; i--) {
                compileExpression(tmplInst.callArguments[i]);
                switch (cast(int)i + arenaShift) {
                    case 0: break;
                    case 1: gen.emitMoveX0ToX1(); break;
                    case 2: gen.emitMoveX0ToX2(); break;
                    case 3: gen.emitMoveX0ToX3(); break;
                    default: assert(0, "argument register > 3");
                }
            }

            // Load arena into x0 if callee needs it
            if (calleeNeedsArena) {
                gen.emitLoadPtr(currentFunctionArenaOffset);
            }

            gen.emitCall(*labelPtr);
            // Check for exception after template call (preserves return value)
            emitNativeExceptionCheckWithValue();
        } else if (auto throwExpr = cast(ThrowExpression)expr) {
            compileThrowExpression(throwExpr);
        } else {
            throw new Exception("Expression type not yet supported in native backend: " ~
                typeid(expr).toString());
        }
    }
    
    /**
     * Emit index assignment: arr[i] = value
     */
    private void emitIndexAssignment(IndexExpression indexExpr, Expression value) {
        // Handle member expression as array source: s.data[i] = value
        if (auto memberExpr = cast(MemberExpression)indexExpr.array) {
            AggregateDecl mAggDecl = getAggregateDeclFromExpr(memberExpr.object);
            if (mAggDecl) {
                auto mField = mAggDecl.getField(memberExpr.memberName);
                if (mField) {
                    if (auto arrType = cast(ArrayType)mField.type) {
                        if (!arrType.isStaticArray) {
                            import codegen.type_marshal : TypeReader;
                            uint elemSize = TypeReader.forNative().elementSizeOf(arrType.elementType);
                            auto mark = temps.save();
                            size_t ptrTemp = temps.alloc(8);
                            size_t valTemp = temps.alloc(8);
                            // Evaluate value first, save to temp
                            compileExpression(value);  // x0 = value
                            gen.emitStoreLocal32(valTemp);
                            // Get slice ptr, save to temp
                            compileExpression(memberExpr);  // x0 = address of slice struct
                            gen.emit(stencil_load_i64);  // x0 = slice.ptr
                            gen.emitStorePtr(ptrTemp);
                            // Compute target address: ptr + index * elemSize
                            compileExpression(indexExpr.index);  // x0 = index
                            gen.emitMoveX0ToX1();
                            gen.emitImm32(stencil_load_imm32, elemSize);
                            gen.emit(stencil_mul_i32);  // x0 = index * elemSize
                            gen.emitMoveX0ToX1();  // x1 = byte offset
                            gen.emitLoadPtr(ptrTemp);  // x0 = ptr
                            gen.emit(stencil_add_i64);  // x0 = target address
                            // Store value
                            gen.emitMoveX0ToX1();  // x1 = target addr (save)
                            gen.emitLoadLocal32(valTemp);  // x0 = value
                            gen.emitMoveX0ToX9();  // x9 = value
                            gen.emitMoveX1ToX0();  // x0 = target addr
                            gen.emitStoreToPointerFromX9(0);
                            temps.restore(mark);
                            return;
                        }
                    }
                }
            }
        }

        // Handle implicit field access in method: data[i] = value
        if (auto currentAgg = currentMethodAggregate()) {
            if (auto ident2 = cast(IdentifierExpression)indexExpr.array) {
                if ((ident2.name in localVars) is null) {
                    auto iField = currentAgg.getField(ident2.name);
                    if (iField) {
                        if (auto arrType = cast(ArrayType)iField.type) {
                            if (!arrType.isStaticArray) {
                                import codegen.type_marshal : TypeReader;
                                uint elemSize = TypeReader.forNative().elementSizeOf(arrType.elementType);
                                auto mark = temps.save();
                                size_t ptrTemp = temps.alloc(8);
                                size_t valTemp = temps.alloc(8);
                                // Evaluate value, save to temp
                                compileExpression(value);
                                gen.emitStoreLocal32(valTemp);
                                // Load slice.ptr from this + field.offset
                                gen.emitLoadPtr(currentThisOffset);
                                if (iField.offset > 0) {
                                    gen.emitMoveX0ToX1();
                                    gen.emitImm32(stencil_load_imm32, cast(int)iField.offset);
                                    gen.emit(stencil_add_i64);
                                }
                                gen.emit(stencil_load_i64);  // x0 = slice.ptr
                                gen.emitStorePtr(ptrTemp);
                                // Compute target address
                                compileExpression(indexExpr.index);
                                gen.emitMoveX0ToX1();
                                gen.emitImm32(stencil_load_imm32, elemSize);
                                gen.emit(stencil_mul_i32);
                                gen.emitMoveX0ToX1();
                                gen.emitLoadPtr(ptrTemp);
                                gen.emit(stencil_add_i64);
                                // Store value
                                gen.emitMoveX0ToX1();
                                gen.emitLoadLocal32(valTemp);
                                gen.emitMoveX0ToX9();
                                gen.emitMoveX1ToX0();
                                gen.emitStoreToPointerFromX9(0);
                                temps.restore(mark);
                                return;
                            }
                        }
                    }
                }
            }
        }

        auto ident = cast(IdentifierExpression)indexExpr.array;
        if (ident is null)
            throw new Exception("Index assignment only supported for local variables in native backend");

        auto info = ident.name in localVars;
        if (info is null)
            throw new Exception("Unknown variable in native backend: " ~ ident.name);

        uint es = info.elemSize;
        final switch (info.kind) {
            case VarKind.staticArray:
                if (es > 4) {
                    // Aggregate element: save 64-bit addresses to temp slots
                    auto mark = temps.save();
                    size_t dstTemp = temps.alloc(8);
                    size_t srcTemp = temps.alloc(8);
                    compileExpression(indexExpr.index);  // x0 = index
                    gen.emitMoveX0ToX1();
                    gen.emitImm32(stencil_load_imm32, es);
                    gen.emit(stencil_mul_i32);  // x0 = index * elemSize
                    gen.emitMoveX0ToX1();
                    gen.emitStackAddress(info.offset);
                    gen.emit(stencil_add_i64);  // x0 = dst address (64-bit ptr)
                    gen.emitStorePtr(dstTemp);
                    compileExpression(value);   // x0 = src address (64-bit)
                    gen.emitStorePtr(srcTemp);
                    // Copy es bytes: 4 bytes at a time
                    for (uint off = 0; off < es; off += 4) {
                        gen.emitLoadPtr(srcTemp);        // x0 = src (64-bit ptr)
                        gen.emitLoadFromPointer(off);      // x0 = *(src + off)
                        gen.emitMoveX0ToX1();              // x1 = value
                        gen.emitLoadPtr(dstTemp);        // x0 = dst (64-bit ptr)
                        gen.emitStoreToPointer(off);       // *(dst + off) = x1
                    }
                    temps.restore(mark);
                    return;
                }
                // Scalar: constant index optimization
                if (auto indexLit = cast(LiteralExpression)indexExpr.index) {
                    if (indexLit.value.type == typeid(long)) {
                        uint idx = cast(uint)indexLit.value.get!long();
                        compileExpression(value);  // x0 = value
                        gen.emitStoreLocal32(info.offset + idx * es);
                        return;
                    }
                }
                // Scalar: dynamic index
                compileExpression(value);  // x0 = value
                gen.emitMoveX0ToX9();      // x9 = value
                compileExpression(indexExpr.index);  // x0 = index
                gen.emitMoveX0ToX1();
                gen.emitImm32(stencil_load_imm32, es);
                gen.emit(stencil_mul_i32);  // x0 = index * elemSize
                gen.emitMoveX0ToX1();
                gen.emitStackAddress(info.offset);
                gen.emit(stencil_add_i64);  // x0 = target address (64-bit ptr)
                gen.emitStoreToPointerFromX9(0);
                return;

            case VarKind.slice:
                if (es > 4) {
                    // Aggregate element: save 64-bit addresses to temp slots
                    auto mark = temps.save();
                    size_t dstTemp = temps.alloc(8);
                    size_t srcTemp = temps.alloc(8);
                    compileExpression(indexExpr.index);  // x0 = index
                    gen.emitMoveX0ToX1();
                    gen.emitImm32(stencil_load_imm32, es);
                    gen.emit(stencil_mul_i32);
                    gen.emitMoveX0ToX1();
                    gen.emitLoadPtr(info.offset);  // x0 = slice ptr (64-bit)
                    gen.emit(stencil_add_i64);  // x0 = dst address (64-bit ptr)
                    gen.emitStorePtr(dstTemp);
                    compileExpression(value);   // x0 = src address (64-bit)
                    gen.emitStorePtr(srcTemp);
                    for (uint off = 0; off < es; off += 4) {
                        gen.emitLoadPtr(srcTemp);
                        gen.emitLoadFromPointer(off);
                        gen.emitMoveX0ToX1();
                        gen.emitLoadPtr(dstTemp);
                        gen.emitStoreToPointer(off);
                    }
                    temps.restore(mark);
                    return;
                }
                // Scalar: store single value
                compileExpression(value);  // x0 = value
                gen.emitMoveX0ToX9();
                compileExpression(indexExpr.index);  // x0 = index
                gen.emitMoveX0ToX1();
                gen.emitImm32(stencil_load_imm32, es);
                gen.emit(stencil_mul_i32);
                gen.emitMoveX0ToX1();
                gen.emitLoadPtr(info.offset);  // x0 = slice ptr (64-bit)
                gen.emit(stencil_add_i64);  // x0 = target address (64-bit ptr)
                gen.emitStoreToPointerFromX9(0);
                return;

            case VarKind.struct_:
                assert(0, "Cannot index-assign struct variable: " ~ ident.name);
            case VarKind.class_:
                assert(0, "Cannot index-assign class variable: " ~ ident.name);
            case VarKind.delegate_:
                assert(0, "Cannot index-assign delegate variable: " ~ ident.name);
            case VarKind.scalar:
                assert(0, "Cannot index-assign scalar variable: " ~ ident.name);
        }
    }

    /**
     * Emit a struct method call: obj.method(args)
     * Passes 'this' pointer (address of obj) as first argument in x0,
     * then user arguments in x1, x2, etc.
     */
    private void emitMethodCall(MemberExpression memberExpr, Expression[] args) {
        log(2, "native: emitMethodCall .", memberExpr.memberName);
        // Handle nested MemberExpression objects (e.g., obj.field.method() from alias-this)
        if (auto objMember = cast(MemberExpression)memberExpr.object) {
            auto innerStruct = getStructDeclFromExpr(objMember);
            if (innerStruct) {
                FunctionDecl method = null;
                foreach (member; innerStruct.members) {
                    if (auto funcDecl = cast(FunctionDecl)member) {
                        if (funcDecl.name == memberExpr.memberName && funcDecl.isMethod) {
                            method = funcDecl;
                            break;
                        }
                    }
                }
                if (method) {
                    string mangledMethodName = getMangledName(method);
                    auto labelPtr = mangledMethodName in functionLabels;
                    if (labelPtr is null)
                        throw new Exception("Method not compiled: " ~ mangledMethodName);

                    bool methodNeedsArena = method.needsArena;
                    int methodArenaShift = methodNeedsArena ? 1 : 0;

                    // Emit arguments into registers (shifted by arena)
                    emitMethodArgs(args, methodArenaShift);

                    // Load arena into x1 if method needs it
                    if (methodNeedsArena) {
                        gen.emitLoadPtr(currentFunctionArenaOffset);
                        gen.emitMoveX0ToX1();
                    }

                    // Compute 'this' pointer: address of nested member
                    compileExpression(objMember);  // leaves address in x0

                    gen.emitCall(*labelPtr);
                    emitNativeExceptionCheckWithValue();
                    return;
                }
            }
            throw new Exception("Cannot resolve method '" ~ memberExpr.memberName ~ "' on nested member expression");
        }

        auto objIdent = cast(IdentifierExpression)memberExpr.object;

        // ObjC chained call: expression receiver (e.g., NSObject.alloc().init_())
        if (!objIdent) {
            if (memberExpr.object.type !is null) {
                auto resolved = memberExpr.object.type.resolve();
                if (auto ifaceDecl = resolved.asInterface()) {
                    if (ifaceDecl.isObjC) {
                        emitObjCCall(ifaceDecl, memberExpr.object, memberExpr.memberName, args, false);
                        return;
                    }
                }
                if (auto classDecl2 = resolved.asClass()) {
                    if (classDecl2.isObjC) {
                        // ObjC class as expression receiver — look up synthetic interface
                        auto sym = symbolTable.lookupSymbol(classDecl2.name);
                        if (sym) {
                            if (auto iface = cast(InterfaceDecl)sym.declaration) {
                                if (iface.isObjC) {
                                    emitObjCCall(iface, memberExpr.object, memberExpr.memberName, args, false);
                                    return;
                                }
                            }
                        }
                        // Fallback: create ad-hoc interface from class methods
                        emitObjCCallFromClass(classDecl2, memberExpr.object, memberExpr.memberName, args, false);
                        return;
                    }
                }
            }
            throw new Exception("Method call on non-identifier object not yet supported in native backend");
        }

        // ObjC static call: type name as receiver (e.g., NSObject.alloc())
        if (objIdent.name !in localVars) {
            auto sym = symbolTable.lookupSymbol(objIdent.name);
            if (sym && sym.kind == SymbolKind.Type) {
                if (auto ifaceDecl = cast(InterfaceDecl)sym.declaration) {
                    if (ifaceDecl.isObjC) {
                        emitObjCCall(ifaceDecl, null, memberExpr.memberName, args, true);
                        return;
                    }
                }
                if (auto classDecl2 = cast(ClassDecl)sym.declaration) {
                    if (classDecl2.isObjC) {
                        emitObjCCallFromClass(classDecl2, null, memberExpr.memberName, args, true);
                        return;
                    }
                }
            }
        }

        // Look up the object to find its type
        auto info = objIdent.name in localVars;
        if (info is null)
            throw new Exception("Unknown variable for method call in native backend: " ~ objIdent.name);

        // ObjC interface variable: dispatch via objc_msgSend
        if (info.isObjCRef && info.interfaceDecl) {
            emitObjCCall(info.interfaceDecl, memberExpr.object, memberExpr.memberName, args, false);
            return;
        }

        // ObjC class variable: dispatch via emitObjCCallFromClass
        log(2, "native: method dispatch isObjCRef=", info.isObjCRef, " classDecl=", info.classDecl !is null, " isObjC=", info.classDecl ? info.classDecl.isObjC : false, " isClass=", info.isClass);
        if (info.isObjCRef && info.classDecl && info.classDecl.isObjC) {
            emitObjCCallFromClass(info.classDecl,
                memberExpr.object, memberExpr.memberName, args, false);
            return;
        }

        // Class method call
        if (info.isClass) {
            // ObjC class variables use objc_msgSend, not D vtable
            if (info.classDecl && info.classDecl.isObjC) {
                emitObjCCallFromClass(info.classDecl,
                    memberExpr.object, memberExpr.memberName, args, false);
                return;
            }
            emitClassMethodCall(info.classDecl, *info, memberExpr.memberName, args);
            return;
        }

        StructDecl structDecl = info.structDecl;
        if (structDecl is null)
            throw new Exception("Method call on non-struct/class variable: " ~ objIdent.name);

        // Find the method in the struct's members
        FunctionDecl method = null;
        foreach (member; structDecl.members) {
            if (auto funcDecl = cast(FunctionDecl)member) {
                if (funcDecl.name == memberExpr.memberName && funcDecl.isMethod) {
                    method = funcDecl;
                    break;
                }
            }
        }

        if (method is null)
            throw new Exception("Struct '" ~ structDecl.name ~ "' has no method '" ~ memberExpr.memberName ~ "'");

        // Look up the mangled function label
        string mangledMethodName = getMangledName(method);
        auto labelPtr = mangledMethodName in functionLabels;
        if (labelPtr is null)
            throw new Exception("Method not compiled: " ~ mangledMethodName);

        bool methodNeedsArena = method.needsArena;
        int methodArenaShift = methodNeedsArena ? 1 : 0;

        if (args.length + methodArenaShift > 3)
            throw new Exception("Native backend: methods support max 3 user arguments (x0 reserved for this)");

        // Emit arguments into registers (shifted by arena)
        emitMethodArgs(args, methodArenaShift);

        // Load arena into x1 if method needs it
        if (methodNeedsArena) {
            gen.emitLoadPtr(currentFunctionArenaOffset);
            gen.emitMoveX0ToX1();
        }

        // Load 'this' pointer into x0
        if (info.isReference)
            gen.emitLoadPtr(info.offset);      // 'this' is already a pointer
        else
            gen.emitStackAddress(info.offset);  // local var: compute stack address

        // Emit the call
        gen.emitCall(*labelPtr);
        // Check for exception after method call (preserves return value)
        emitNativeExceptionCheckWithValue();
        // Result is in x0
    }

    /**
     * Emit a class method call with virtual dispatch.
     * Looks up the method in the class hierarchy, finds its vtable slot,
     * and emits an indirect call through the vtable.
     */
    private void emitClassMethodCall(ClassDecl classDecl, NativeLocalInfo info, string methodName, Expression[] args) {
        log(2, "native: emitClassMethodCall ", classDecl.name, ".", methodName);
        assert(classDecl !is null, "emitClassMethodCall: classDecl is null");
        ensureNativeVtable(classDecl);
        computeVirtualMethodsIfNeeded(classDecl);

        // Find method in class hierarchy (walk base classes)
        FunctionDecl method = findMethodInClass(classDecl, methodName);
        if (method is null)
            throw new Exception("Class '" ~ classDecl.name ~ "' has no method '" ~ methodName ~ "'");

        // Find vtable slot index
        int slotIdx = findVtableSlot(classDecl, method);
        assert(slotIdx >= 0, "Method '" ~ methodName ~ "' not found in vtable for class '" ~ classDecl.name ~ "'");

        bool methodNeedsArena = method.needsArena;
        int arenaShift = methodNeedsArena ? 1 : 0;

        auto mark = temps.save();
        size_t funcPtrTemp = temps.alloc(8);

        // Step 1: Compute function pointer via vtable and save to temp.
        // Must happen BEFORE emitMethodArgs, because vtable lookup clobbers x0/x1.
        assert(vtableStartOffset != size_t.max, "vtable not allocated for class " ~ classDecl.name);

        // Load vtable base index from the class instance.
        // For references (e.g. 'this'), dereference the pointer first.
        // For local instances, read directly from stack.
        if (info.isReference) {
            gen.emitLoadPtr(info.offset);      // x0 = pointer to instance
            gen.emitLoadFromPointer(0);        // w0 = vtable base index at instance offset 0
        } else {
            gen.emitLoadLocal32(info.offset);  // w0 = vtable base index
        }
        if (slotIdx > 0) {
            gen.emitMoveX0ToX1();
            gen.emitImm32(stencil_load_imm32, slotIdx);
            gen.emit(stencil_add_i32);
        }

        if (objectMode) {
            // Object mode: load vtable base via ADRP+ADD
            // Save slot index to temp first since ADRP+ADD clobbers x0
            gen.emitStoreLocal32(funcPtrTemp);

            emitLoadDataAddress("__vtable");    // x0 = vtable base address
            gen.emitMoveX0ToX9();               // x9 = vtable base

            gen.emitLoadLocal32(funcPtrTemp);   // w0 = slot index
        } else {
            // JIT mode: hardcoded data section address
            gen.emitLoadImm64ToX9(cast(ulong)(cast(size_t)dataSection.base + vtableStartOffset));
        }
        // x9 = x9 + x0 * 8 (index into function pointer array)
        gen.emitAddX9X0LSL3();
        // x9 = *x9 (load function pointer from vtable slot)
        gen.emitLoadFromX9();
        // Save function pointer to temp
        gen.emitMoveX9ToX0();
        gen.emitStorePtr(funcPtrTemp);

        // Step 2: Load user arguments into registers
        emitMethodArgs(args, arenaShift);

        // Step 3: Load arena into x1 if method needs it
        if (methodNeedsArena) {
            gen.emitLoadPtr(currentFunctionArenaOffset);
            gen.emitMoveX0ToX1();
        }

        // Step 4: Restore function pointer into x9
        gen.emitLoadPtr(funcPtrTemp);
        gen.emitMoveX0ToX9();

        // Step 5: Load 'this' pointer into x0
        // For references, load the stored pointer; for locals, compute stack address.
        if (info.isReference)
            gen.emitLoadPtr(info.offset);
        else
            gen.emitStackAddress(info.offset);

        // Step 6: Indirect call via x9
        gen.emitCallIndirectX9();
        // Check for exception after virtual method call (preserves return value)
        emitNativeExceptionCheckWithValue();
        temps.restore(mark);
        // Result is in x0
    }

    /// Find a method by name in a class hierarchy (walks base classes).
    private FunctionDecl findMethodInClass(ClassDecl classDecl, string methodName) {
        // Search this class first, then walk up base classes
        ClassDecl current = classDecl;
        while (current !is null) {
            foreach (member; current.members) {
                if (auto funcDecl = cast(FunctionDecl)member) {
                    if (funcDecl.name == methodName && funcDecl.isMethod) {
                        return funcDecl;
                    }
                }
            }
            current = current.baseClassDecl;
        }
        return null;
    }

    /// Find the vtable slot index for a method in a class.
    private int findVtableSlot(ClassDecl classDecl, FunctionDecl method) {
        computeVirtualMethodsIfNeeded(classDecl);
        string mangledName = getMangledName(method);
        foreach (i, vm; classDecl.virtualMethods) {
            if (getMangledName(vm) == mangledName)
                return cast(int)i;
        }
        return -1;
    }

    /**
     * Emit a struct-returning method call for native backend.
     * Handles both struct (direct call) and class (virtual dispatch) receivers.
     * The result is written directly to resultOffset on the caller's stack frame.
     *
     * ARM64 calling convention for struct-returning methods:
     *   x0 = result_ptr (where callee writes struct data)
     *   x1 = this_ptr (address of the object)
     *   [x2 = arena if needed]
     *   x2+/x3+ = user args
     */
    private void emitStructReturnMethodCallNative(MemberExpression memberFunc,
            Expression[] args, size_t resultOffset) {
        auto objIdent = cast(IdentifierExpression)memberFunc.object;
        assert(objIdent !is null,
            "Struct-returning method call on non-identifier not yet supported in native backend");

        auto info = objIdent.name in localVars;
        assert(info !is null, "Unknown variable '" ~ objIdent.name ~ "' for struct-returning method call");

        if (info.isClass) {
            // Virtual dispatch with hidden result pointer
            ClassDecl classDecl = info.classDecl;
            assert(classDecl !is null, "Class info without classDecl for " ~ objIdent.name);

            ensureNativeVtable(classDecl);

            FunctionDecl method = findMethodInClass(classDecl, memberFunc.memberName);
            assert(method !is null,
                "Class '" ~ classDecl.name ~ "' has no method '" ~ memberFunc.memberName ~ "'");

            computeVirtualMethodsIfNeeded(classDecl);

            int slotIdx = findVtableSlot(classDecl, method);
            assert(slotIdx >= 0,
                "Method '" ~ memberFunc.memberName ~ "' not in vtable for class '" ~ classDecl.name ~ "'");

            bool methodNeedsArena = method.needsArena;
            int arenaShift = methodNeedsArena ? 1 : 0;

            auto mark = temps.save();
            size_t funcPtrTemp = temps.alloc(8);

            // Step 1: Compute function pointer via vtable and save to temp
            assert(vtableStartOffset != size_t.max, "vtable not allocated");

            // Load vtable base index (dereference pointer for references like 'this')
            if (info.isReference) {
                gen.emitLoadPtr(info.offset);
                gen.emitLoadFromPointer(0);
            } else {
                gen.emitLoadLocal32(info.offset);
            }
            if (slotIdx > 0) {
                gen.emitMoveX0ToX1();
                gen.emitImm32(stencil_load_imm32, slotIdx);
                gen.emit(stencil_add_i32);
            }

            if (objectMode) {
                gen.emitStoreLocal32(funcPtrTemp);  // save slot index

                emitLoadDataAddress("__vtable");
                gen.emitMoveX0ToX9();

                gen.emitLoadLocal32(funcPtrTemp);   // restore slot index
            } else {
                gen.emitLoadImm64ToX9(cast(ulong)(cast(size_t)dataSection.base + vtableStartOffset));
            }
            gen.emitAddX9X0LSL3();
            gen.emitLoadFromX9();
            gen.emitMoveX9ToX0();
            gen.emitStorePtr(funcPtrTemp);

            // Step 2: Load user arguments (shifted by this + result_ptr + arena)
            for (long i = cast(long)args.length - 1; i >= 0; i--) {
                compileExpression(args[i]);
                switch (cast(int)i + 2 + arenaShift) {
                    case 2: gen.emitMoveX0ToX2(); break;
                    case 3: gen.emitMoveX0ToX3(); break;
                    default: assert(0, "Too many args for struct-returning virtual method");
                }
            }

            // Step 3: Load arena into x2 if needed
            if (methodNeedsArena) {
                gen.emitLoadPtr(currentFunctionArenaOffset);
                gen.emitMoveX0ToX2();
            }

            // Step 4: Load 'this' into x1 (pointer value for refs, stack address for locals)
            if (info.isReference)
                gen.emitLoadPtr(info.offset);
            else
                gen.emitStackAddress(info.offset);
            gen.emitMoveX0ToX1();

            // Step 5: Load result pointer into x0
            gen.emitStackAddress(resultOffset);

            // Step 6: Restore function pointer and call
            // Save x0 (result_ptr), load func ptr, save to x9, restore x0
            gen.emitMoveX0ToX9();  // x9 = result_ptr temporarily
            gen.emitLoadPtr(funcPtrTemp);
            // Now x0 = func_ptr, x9 = result_ptr — need to swap
            // Use stack to swap: save func_ptr, restore result_ptr to x0, restore func_ptr to x9
            gen.emitStorePtr(funcPtrTemp);  // funcPtrTemp = func_ptr again
            gen.emitMoveX9ToX0();           // x0 = result_ptr
            gen.emitLoadPtr(funcPtrTemp);
            gen.emitMoveX0ToX9();           // x9 = func_ptr
            gen.emitStackAddress(resultOffset);  // x0 = result_ptr (reload cleanly)

            gen.emitCallIndirectX9();
            emitNativeExceptionCheck();
            temps.restore(mark);
        } else if (info.isStruct) {
            // Direct struct method call with hidden result pointer
            StructDecl structDecl = info.structDecl;
            assert(structDecl !is null, "Struct info without structDecl for " ~ objIdent.name);

            FunctionDecl method = null;
            foreach (member; structDecl.members) {
                if (auto funcDecl = cast(FunctionDecl)member) {
                    if (funcDecl.name == memberFunc.memberName && funcDecl.isMethod) {
                        method = funcDecl;
                        break;
                    }
                }
            }
            assert(method !is null,
                "Struct '" ~ structDecl.name ~ "' has no method '" ~ memberFunc.memberName ~ "'");

            string mangledName = getMangledName(method);
            auto labelPtr = mangledName in functionLabels;
            assert(labelPtr !is null, "Method not compiled: " ~ mangledName);

            bool methodNeedsArena = method.needsArena;
            int arenaShift = methodNeedsArena ? 1 : 0;

            // Args start at x(2+arenaShift) for struct-returning methods
            for (long i = cast(long)args.length - 1; i >= 0; i--) {
                compileExpression(args[i]);
                switch (cast(int)i + 2 + arenaShift) {
                    case 2: gen.emitMoveX0ToX2(); break;
                    case 3: gen.emitMoveX0ToX3(); break;
                    default: assert(0, "Too many args for struct-returning method");
                }
            }

            if (methodNeedsArena) {
                gen.emitLoadPtr(currentFunctionArenaOffset);
                gen.emitMoveX0ToX2();
            }

            // x1 = this pointer
            if (info.isReference)
                gen.emitLoadPtr(info.offset);
            else
                gen.emitStackAddress(info.offset);
            gen.emitMoveX0ToX1();

            // x0 = result pointer
            gen.emitStackAddress(resultOffset);

            gen.emitCall(*labelPtr);
            emitNativeExceptionCheck();
        } else {
            throw new Exception("Struct-returning method call on non-struct/class variable: " ~ objIdent.name);
        }
    }

    /// Emit method call arguments into registers.
    /// arenaShift=0: args go into x1, x2, x3 (no arena)
    /// arenaShift=1: args go into x2, x3, x4 (x1 reserved for arena)
    private void emitMethodArgs(Expression[] args, int arenaShift = 0) {
        if (args.length + arenaShift > 3)
            throw new Exception("Native backend: methods support max 3 user arguments (x0 reserved for this)");

        // Check if any argument contains a function call that would clobber registers
        bool hasNestedCalls = false;
        foreach (arg; args) {
            if (containsCall(arg)) {
                hasNestedCalls = true;
                break;
            }
        }

        if (hasNestedCalls && args.length > 1) {
            // Save arguments to temp slots, then load into registers
            auto mark = temps.save();
            size_t[] argSlots;
            foreach (i, arg; args) {
                compileExpression(arg);
                size_t slot = temps.alloc(8);
                gen.emitStorePtr(slot);
                argSlots ~= slot;
            }
            // Load from temp slots into registers (reverse order to not clobber)
            for (long i = cast(long)argSlots.length - 1; i >= 0; i--) {
                gen.emitLoadPtr(argSlots[cast(size_t)i]);
                switch (cast(int)i + 1 + arenaShift) {
                    case 1: gen.emitMoveX0ToX1(); break;
                    case 2: gen.emitMoveX0ToX2(); break;
                    case 3: gen.emitMoveX0ToX3(); break;
                    default: assert(0, "method argument register > 3");
                }
            }
            temps.restore(mark);
        } else {
            // No nested calls - direct register assignment (reverse order)
            for (long i = cast(long)args.length - 1; i >= 0; i--) {
                compileExpression(args[i]);
                switch (cast(int)i + 1 + arenaShift) {
                    case 1: gen.emitMoveX0ToX1(); break;
                    case 2: gen.emitMoveX0ToX2(); break;
                    case 3: gen.emitMoveX0ToX3(); break;
                    default: assert(0, "method argument register > 3");
                }
            }
        }
    }

    /**
     * Emit call stack push - store call frame data and call __ctfe_push_call
     */
    private void emitPushCall(string funcName, string fileName, uint line) {
        import codegen.native.arm64_codegen : CallFrameData;
        
        // Store function name and file name in data section
        ubyte* namePtr = dataSection.addString(funcName);
        ubyte* filePtr = dataSection.addString(fileName);
        if (namePtr is null || filePtr is null) return;  // Out of space, skip tracking
        
        // Build CallFrameData struct in data section
        CallFrameData frameData;
        frameData.namePtr = cast(ulong)namePtr;
        frameData.nameLen = cast(uint)funcName.length;
        frameData.filePtr = cast(ulong)filePtr;
        frameData.fileLen = cast(uint)fileName.length;
        frameData.line = line;
        
        ubyte* framePtr = dataSection.addData((cast(ubyte*)&frameData)[0..CallFrameData.sizeof]);
        if (framePtr is null) return;
        
        // Load frame pointer into x0
        gen.emitLoadImm64(cast(ulong)framePtr);  // x0 = framePtr
        
        ulong slot = hostFunctions.getFunctionSlotAddress("__ctfe_push_call");
        ulong ctxSlot = hostFunctions.getContextSlotAddress();
        gen.emitHostCall(slot, ctxSlot);
    }
    
    /**
     * Emit call stack pop - call __ctfe_pop_call
     */
    private void emitPopCall() {
        // No arguments needed, emitHostCall will inject context
        ulong slot = hostFunctions.getFunctionSlotAddress("__ctfe_pop_call");
        ulong ctxSlot = hostFunctions.getContextSlotAddress();
        gen.emitHostCall(slot, ctxSlot);
    }
    
    /**
     * Emit inline call stack push - writes directly to data section, no FFI
     * Uses x8, x9, x10, x11, x12, x13 as scratch (saves/restores x0)
     */
    private void emitInlinePushCall(string funcName, string fileName, uint line) {
        import codegen.native.codegen_interface : InlineFrame, INLINE_STACK_DEPTH_OFFSET,
            INLINE_STACK_MAX_DEPTH, INLINE_STACK_FRAMES_OFFSET, INLINE_FRAME_SIZE;
        import std.stdio : writefln;
        
        // Add strings to data section, get their offsets
        size_t nameOffset = dataSection.bytesUsed;
        auto namePtr = dataSection.addString(funcName);
        if (namePtr is null) return;
        
        size_t fileOffset = dataSection.bytesUsed;
        auto filePtr = dataSection.addString(fileName);
        if (filePtr is null) return;
        
        // Build InlineFrame in data section
        InlineFrame frame;
        frame.nameOffset = cast(uint)nameOffset;
        frame.nameLen = cast(uint)funcName.length;
        frame.fileOffset = cast(uint)fileOffset;
        frame.fileLen = cast(uint)fileName.length;
        frame.line = line;
        frame.column = 0;
        
        size_t frameDataOffset = dataSection.bytesUsed;
        auto framePtr = dataSection.addData((cast(ubyte*)&frame)[0..InlineFrame.sizeof]);
        if (framePtr is null) return;
        
        // Save x0 (might contain pointer — must use 64-bit store)
        auto mark = temps.save();
        size_t pushSave = temps.alloc(8);
        gen.emitStorePtr(pushSave);

        // Load data section base into x10
        gen.emitLoadImm64(cast(ulong)dataSection.base);
        gen.emitMoveX0ToX10();

        // Emit inline push code
        gen.emitInlineStackPush(cast(uint)frameDataOffset);

        // Restore x0
        gen.emitLoadPtr(pushSave);
        temps.restore(mark);
    }
    
    /**
     * Emit inline call stack pop - decrements depth in data section, no FFI
     * Uses x8, x10 as scratch (does NOT touch x0, safe for return values)
     */
    private void emitInlinePopCall() {
        // Save x0 (return value) to stack FIRST, before we clobber it
        auto mark = temps.save();
        size_t popSave = temps.alloc(8);
        gen.emitStorePtr(popSave);

        // Load data section base into x10 (clobbers x0, but we saved it)
        gen.emitLoadImm64(cast(ulong)dataSection.base);
        gen.emitMoveX0ToX10();

        // Emit inline pop code (uses x8, so we can't save return value there)
        gen.emitInlineStackPop();

        // Restore x0 (return value) from stack
        gen.emitLoadPtr(popSave);
        temps.restore(mark);
    }
    
    /**
     * Emit bounds check: if index < 0 or index >= length, call __ctfe_trap.
     * Assumes: index in x0
     * Slice layout: { ptr: i64, length: i32, capacity: i32 } at sliceOffset (16 bytes)
     * Preserves: x0 (index)
     */
    private void emitBoundsCheck(size_t sliceOffset, string fileName, uint line, uint column) {
        auto okLabel = gen.newLabel();

        auto mark = temps.save();
        size_t myTempSlot = temps.alloc(8);

        // Save index to temp (we need it after bounds check)
        gen.emitStoreLocal32(myTempSlot);

        // Load length from slice (offset 8 = after 64-bit ptr)
        gen.emitLoadLocal32(sliceOffset + sliceInfo.lengthOffset);  // x0 = length
        gen.emitMoveX0ToX1();  // x1 = length

        // Reload index
        gen.emitLoadLocal32(myTempSlot);  // x0 = index

        // Compare: if index < length (unsigned), OK; else error
        gen.emit(stencil_lt_u32);  // x0 = (index < length) ? 1 : 0
        gen.emitBranchIfNonZero(okLabel);  // branch if index < length

        emitRuntimeError("array index out of bounds", fileName, line);

        gen.bindLabel(okLabel);
        // Restore index to x0
        gen.emitLoadLocal32(myTempSlot);  // x0 = index

        temps.restore(mark);
    }
    
    /**
     * Emit checked division: if divisor is 0, call __ctfe_trap.
     * Assumes: dividend in x0, divisor in x1
     * Result: quotient in x0
     */
    private void emitCheckedDiv(string fileName, uint line, uint column) {
        auto errorLabel = gen.newLabel();
        auto doneLabel = gen.newLabel();
        
        // CBZ x1, error  (branch if divisor is zero)
        gen.emitBranchIfZeroX1(errorLabel);
        
        // SDIV x0, x0, x1
        gen.emit(stencil_div_i32);
        
        // B done (skip error handler)
        gen.emitBranch(doneLabel);
        
        // .Ldiv_error:
        gen.bindLabel(errorLabel);

        emitRuntimeError("division by zero", fileName, line);

        // .Ldiv_done:
        gen.bindLabel(doneLabel);
    }
    
    /**
     * Emit checked modulo: if divisor is 0, call __ctfe_trap.
     * Assumes: dividend in x0, divisor in x1
     * Result: remainder in x0
     */
    private void emitCheckedMod(string fileName, uint line, uint column) {
        auto errorLabel = gen.newLabel();
        auto doneLabel = gen.newLabel();
        
        gen.emitBranchIfZeroX1(errorLabel);
        gen.emit(stencil_mod_i32);
        gen.emitBranch(doneLabel);
        
        gen.bindLabel(errorLabel);

        emitRuntimeError("modulo by zero", fileName, line);

        gen.bindLabel(doneLabel);
    }
    
    /**
     * Emit a runtime error message and _exit(1) for object mode.
     * Builds the error string at compile time, stores in __DATA,__const,
     * emits ADRP+ADD to load its address, then calls write(2, msg, len) + _exit(1).
     */
    /// Compile arguments into x0-x3 following the C calling convention.
    /// Used for both JIT FFI calls and object-mode extern(C) calls.
    private void emitCCallArgs(Expression[] arguments) {
        if (arguments.length > 4)
            throw new Exception("Native backend: C calls support max 4 arguments");

        bool hasNestedCalls = false;
        foreach (arg; arguments) {
            if (containsCall(arg)) {
                hasNestedCalls = true;
                break;
            }
        }

        if (hasNestedCalls && arguments.length > 1) {
            auto mark = temps.save();
            size_t[] argSlots;
            foreach (i, arg; arguments) {
                compileExpression(arg);
                size_t slot = temps.alloc(8);
                gen.emitStorePtr(slot);
                argSlots ~= slot;
            }
            for (long i = cast(long)argSlots.length - 1; i >= 0; i--) {
                gen.emitLoadPtr(argSlots[cast(size_t)i]);
                switch (cast(int)i) {
                    case 0: break;
                    case 1: gen.emitMoveX0ToX1(); break;
                    case 2: gen.emitMoveX0ToX2(); break;
                    case 3: gen.emitMoveX0ToX3(); break;
                    default: assert(0, "C call argument register > 3");
                }
            }
            temps.restore(mark);
        } else {
            for (long i = cast(long)arguments.length - 1; i >= 0; i--) {
                compileExpression(arguments[i]);
                switch (cast(int)i) {
                    case 0: break;
                    case 1: gen.emitMoveX0ToX1(); break;
                    case 2: gen.emitMoveX0ToX2(); break;
                    case 3: gen.emitMoveX0ToX3(); break;
                    default: assert(0, "C call argument register > 3");
                }
            }
        }
    }

    private void emitRuntimeError(string errorKind, string fileName, uint line) {
        import std.conv : to;
        string msg = "Runtime Error: " ~ errorKind ~ " at " ~ fileName ~ ":" ~ to!string(line) ~ "\n";

        // Load msg address into x0
        emitStringLoad(msg, "__err_");

        // Set up write(2, msg, len): x0=fd, x1=buf, x2=len
        gen.emitMoveX0ToX1();                  // x1 = msg pointer
        gen.emitLoadImm(cast(int)msg.length);  // x0 = msg length
        gen.emitMoveX0ToX2();                  // x2 = msg length
        gen.emitLoadImm(2);                    // x0 = 2 (stderr)
        emitExternalOrHostCall("write");

        // _exit(1)
        gen.emitLoadImm(1);                    // x0 = 1 (exit code)
        emitExternalOrHostCall("_exit");
    }

    /// Emit a call to an external function. Works in both modes:
    /// Object: BL with BRANCH26 relocation.
    /// JIT: resolve via dlsym and call indirectly via x9.
    private void emitExternalOrHostCall(string funcName) {
        if (objectMode) {
            emitObjectExternalCall(funcName);
        } else {
            // JIT mode: resolve via dlsym and call directly
            import core.sys.posix.dlfcn : dlsym;
            version (OSX) {
                import core.sys.darwin.dlfcn : RTLD_DEFAULT;
            } else {
                import core.sys.posix.dlfcn : RTLD_DEFAULT;
            }
            auto ptr = dlsym(RTLD_DEFAULT, (funcName ~ "\0").ptr);
            if (ptr !is null) {
                gen.emitLoadImm64ToX9(cast(ulong)cast(size_t)ptr);
                gen.emitCallIndirectX9();
            }
        }
    }

    /**
     * Compile struct construction: allocate space on stack, initialize fields
     */
    private void compileStructConstruction(StructDecl structDecl, Expression[] args) {
        size_t structSize = structDecl.structSize;
        auto mark = temps.save();
        size_t structOffset = temps.alloc(structSize);
        assert(structDecl.fields.length > 0,
            "Struct '" ~ structDecl.name ~ "' has no fields");
        
        // Initialize each field from arguments
        for (size_t i = 0; i < structDecl.fields.length && i < args.length; i++) {
            auto field = structDecl.fields[i];
            size_t fieldOffset = structOffset + field.offset;
            
            // Compile the argument value (into x0)
            compileExpression(args[i]);
            
            // Store to the field's stack location
            gen.emitStoreLocal32(fieldOffset);
        }
        
        // Leave pointer to struct in x0 (stack pointer + offset)
        // For now, we use the stack offset directly since our loads expect offsets
        // Actually, for member access to work, we need the actual pointer
        // Let's compute: x0 = sp + structOffset
        gen.emitLoadStackPointer();
        gen.emitMoveX0ToX1();
        gen.emitImm32(stencil_load_imm32, cast(int)structOffset);
        gen.emit(stencil_add_i64);  // 64-bit ptr arithmetic
        // Now x0 = pointer to struct (stack memory persists; caller copies before next alloc)
        temps.restore(mark);
    }
    
    /**
     * Compile slice initialization from array literal directly to a stack location.
     * Native slice layout: { ptr: i64, length: i32, capacity: i32 } = sliceInfo.totalSize bytes
     * (Unlike WASM which uses 32-bit pointers, native ARM64 needs 64-bit)
     */
    private void compileSliceInit(size_t sliceOffset, ArrayLiteralExpression arrLit) {
        uint elemCount = cast(uint)arrLit.elements.length;
        uint dataSize = elemCount * 4;  // 4 bytes per int element
        
        // Data goes right after the 16-byte slice struct
        size_t dataOffset = sliceOffset + 16;
        
        // Initialize data elements
        foreach (i, elem; arrLit.elements) {
            compileExpression(elem);
            gen.emitStoreLocal32(dataOffset + i * 4);
        }
        
        // Initialize slice struct at sliceOffset
        // ptr = sp + dataOffset (64-bit pointer!)
        gen.emitLoadStackPointer();
        gen.emitMoveX0ToX1();
        gen.emitImm32(stencil_load_imm32, cast(int)dataOffset);
        gen.emit(stencil_add_i64);  // 64-bit ptr arithmetic
        gen.emitStorePtr(sliceOffset);  // store 64-bit ptr
        
        // length = elemCount (32-bit at offset 8)
        gen.emitImm32(stencil_load_imm32, cast(int)elemCount);
        gen.emitStoreLocal32(sliceOffset + sliceInfo.lengthOffset);  // store length
        
        // capacity = elemCount (32-bit at offset 12)
        gen.emitImm32(stencil_load_imm32, cast(int)elemCount);
        gen.emitStoreLocal32(sliceOffset + sliceInfo.capacityOffset);  // store capacity
    }
    
    /**
     * Compile import() initialization for a slice variable.
     * Milestone 86: Native backend import() support.
     * 
     * Reads the file at compile time, stores contents in dataSection,
     * and initializes the slice to point to that data.
     */
    private void compileImportInit(size_t sliceOffset, ImportExpression importExpr) {
        import std.file : read, exists;
        import std.path : buildPath, dirName;
        
        string filename = importExpr.filename;
        
        // Try to find the file relative to the source file
        string sourcePath = importExpr.location.filename;
        string sourceDir = sourcePath.length > 0 ? dirName(sourcePath) : ".";
        string fullPath = buildPath(sourceDir, filename);
        
        // Also try current directory if not found
        if (!exists(fullPath)) {
            fullPath = filename;
        }
        
        if (!exists(fullPath)) {
            throw new Exception("import(): file not found: " ~ filename);
        }
        
        // Read the file
        ubyte[] fileData = cast(ubyte[])read(fullPath);
        uint len = cast(uint)fileData.length;

        // Store file data and load its address into x0
        emitDataLoad(fileData, "__import_");
        gen.emitStorePtr(sliceOffset);

        // length = len (32-bit at offset 8)
        gen.emitImm32(stencil_load_imm32, cast(int)len);
        gen.emitStoreLocal32(sliceOffset + sliceInfo.lengthOffset);

        // capacity = len (32-bit at offset 12)
        gen.emitImm32(stencil_load_imm32, cast(int)len);
        gen.emitStoreLocal32(sliceOffset + sliceInfo.capacityOffset);
    }

    /// Initialize a slice from a string literal by storing bytes in the data section.
    private void compileStringLiteralInit(size_t sliceOffset, string strVal) {
        uint len = cast(uint)strVal.length;

        // Store string data and load its address into x0
        emitStringLoad(strVal);
        gen.emitStorePtr(sliceOffset);

        // length (32-bit at offset 8)
        gen.emitImm32(stencil_load_imm32, cast(int)len);
        gen.emitStoreLocal32(sliceOffset + sliceInfo.lengthOffset);

        // capacity (32-bit at offset 12)
        gen.emitImm32(stencil_load_imm32, cast(int)len);
        gen.emitStoreLocal32(sliceOffset + sliceInfo.capacityOffset);
    }

    /**
     * Compile array/string concatenation: a ~ b
     *
     * Both operands produce addresses of slice structs (ptr:i64, len:i32, cap:i32).
     * Allocates a new buffer of (leftLen + rightLen) bytes, copies both halves,
     * builds a result slice struct on the stack, returns its address in x0.
     */
    private void compileArrayConcat(BinaryExpression binOp) {
        auto mark = temps.save();

        // Temps for slice struct addresses and extracted fields
        size_t tempLeftSlice  = temps.alloc(8);
        size_t tempRightSlice = temps.alloc(8);
        size_t tempLeftPtr    = temps.alloc(8);
        size_t tempLeftLen    = temps.alloc(8);
        size_t tempRightPtr   = temps.alloc(8);
        size_t tempRightLen   = temps.alloc(8);
        size_t tempTotalLen   = temps.alloc(8);
        size_t tempNewBuf     = temps.alloc(8);
        size_t tempLoopIdx    = temps.alloc(8);

        // 1. Evaluate left operand → x0 = address of left slice struct
        compileExpression(binOp.left);
        gen.emitStorePtr(tempLeftSlice);

        // 2. Evaluate right operand → x0 = address of right slice struct
        compileExpression(binOp.right);
        gen.emitStorePtr(tempRightSlice);

        // 3. Extract left.ptr (8-byte at offset 0) and left.length (4-byte at lengthOffset)
        gen.emitLoadPtr(tempLeftSlice);         // x0 = &leftSlice
        gen.emit(stencil_load_i64);             // x0 = leftSlice.ptr (64-bit)
        gen.emitStorePtr(tempLeftPtr);

        gen.emitLoadPtr(tempLeftSlice);         // x0 = &leftSlice
        gen.emitLoadFromPointer(sliceInfo.lengthOffset);  // x0 = leftSlice.length (32-bit)
        gen.emitStoreLocal32(tempLeftLen);

        // 4. Extract right.ptr and right.length
        gen.emitLoadPtr(tempRightSlice);
        gen.emit(stencil_load_i64);
        gen.emitStorePtr(tempRightPtr);

        gen.emitLoadPtr(tempRightSlice);
        gen.emitLoadFromPointer(sliceInfo.lengthOffset);
        gen.emitStoreLocal32(tempRightLen);

        // 5. totalLen = leftLen + rightLen
        gen.emitLoadLocal32(tempLeftLen);
        gen.emitMoveX0ToX1();
        gen.emitLoadLocal32(tempRightLen);
        gen.emit(stencil_add_i32);              // x0 = leftLen + rightLen
        gen.emitStoreLocal32(tempTotalLen);

        // 6. Allocate buffer of totalLen bytes
        gen.emitLoadLocal32(tempTotalLen);       // x0 = size
        ulong allocSlot = hostFunctions.getFunctionSlotAddress("__ctfe_alloc");
        if (allocSlot != 0) {
            ulong contextSlot = hostFunctions.getContextSlotAddress();
            gen.emitHostCall(allocSlot, contextSlot);
        } else {
            emitExternalOrHostCall("malloc");
        }
        gen.emitStorePtr(tempNewBuf);            // save new buffer ptr

        // 7. Copy left half: leftLen bytes from leftPtr to newBuf
        gen.emitImm32(stencil_load_imm32, 0);
        gen.emitStoreLocal32(tempLoopIdx);       // i = 0

        auto copyLeftStart = gen.newLabel();
        auto copyLeftEnd   = gen.newLabel();
        gen.bindLabel(copyLeftStart);

        // if (i >= leftLen) break
        gen.emitLoadLocal32(tempLoopIdx);
        gen.emitMoveX0ToX1();
        gen.emitLoadLocal32(tempLeftLen);
        gen.emitMoveX0ToX2();
        gen.emit(stencil_move_arg1_to_result);   // x0 = i
        gen.emit(stencil_move_arg2_to_arg1);     // x1 = leftLen
        gen.emit(stencil_ge_i32);                // x0 = (i >= leftLen)
        gen.emitBranchIfNonZero(copyLeftEnd);

        // Load byte from leftPtr + i
        gen.emitLoadLocal32(tempLoopIdx);        // x0 = i
        gen.emitMoveX0ToX1();
        gen.emitLoadPtr(tempLeftPtr);            // x0 = leftPtr
        gen.emit(stencil_add_i64);               // x0 = leftPtr + i
        gen.emitLoadByteFromPointer(0);          // x0 = byte at [leftPtr + i]
        gen.emitMoveX0ToX2();                    // x2 = byte value

        // Store byte to newBuf + i
        gen.emitLoadLocal32(tempLoopIdx);        // x0 = i
        gen.emitMoveX0ToX1();
        gen.emitLoadPtr(tempNewBuf);             // x0 = newBuf
        gen.emit(stencil_add_i64);               // x0 = newBuf + i
        gen.emit(stencil_move_arg2_to_arg1);     // x1 = byte value
        gen.emitStoreByteToPointer(0);           // [newBuf + i] = byte

        gen.emitIncLocal32(tempLoopIdx);
        gen.emitBranch(copyLeftStart);
        gen.bindLabel(copyLeftEnd);

        // 8. Copy right half: rightLen bytes from rightPtr to newBuf + leftLen
        gen.emitImm32(stencil_load_imm32, 0);
        gen.emitStoreLocal32(tempLoopIdx);       // i = 0

        auto copyRightStart = gen.newLabel();
        auto copyRightEnd   = gen.newLabel();
        gen.bindLabel(copyRightStart);

        // if (i >= rightLen) break
        gen.emitLoadLocal32(tempLoopIdx);
        gen.emitMoveX0ToX1();
        gen.emitLoadLocal32(tempRightLen);
        gen.emitMoveX0ToX2();
        gen.emit(stencil_move_arg1_to_result);
        gen.emit(stencil_move_arg2_to_arg1);
        gen.emit(stencil_ge_i32);
        gen.emitBranchIfNonZero(copyRightEnd);

        // Load byte from rightPtr + i
        gen.emitLoadLocal32(tempLoopIdx);
        gen.emitMoveX0ToX1();
        gen.emitLoadPtr(tempRightPtr);
        gen.emit(stencil_add_i64);
        gen.emitLoadByteFromPointer(0);
        gen.emitMoveX0ToX2();                    // x2 = byte value

        // Store byte to newBuf + leftLen + i
        gen.emitLoadLocal32(tempLeftLen);         // x0 = leftLen
        gen.emitMoveX0ToX1();
        gen.emitLoadLocal32(tempLoopIdx);         // x0 = i
        gen.emit(stencil_add_i32);                // x0 = leftLen + i (32-bit offset)
        gen.emitMoveX0ToX1();                     // x1 = leftLen + i
        gen.emitLoadPtr(tempNewBuf);              // x0 = newBuf
        gen.emit(stencil_add_i64);                // x0 = newBuf + leftLen + i
        gen.emit(stencil_move_arg2_to_arg1);      // x1 = byte value
        gen.emitStoreByteToPointer(0);

        gen.emitIncLocal32(tempLoopIdx);
        gen.emitBranch(copyRightStart);
        gen.bindLabel(copyRightEnd);

        // 9. Allocate result slice struct on stack (permanent frame space, not temp)
        size_t resultOffset = (nextLocalOffset + 7) & ~7;  // 8-byte align
        nextLocalOffset = resultOffset + sliceInfo.totalSize;

        // Store ptr (64-bit) — read tempNewBuf before temps.restore
        gen.emitLoadPtr(tempNewBuf);
        gen.emitStorePtr(resultOffset);

        // Store length (32-bit)
        gen.emitLoadLocal32(tempTotalLen);
        gen.emitStoreLocal32(resultOffset + sliceInfo.lengthOffset);

        // Store capacity (32-bit)
        gen.emitLoadLocal32(tempTotalLen);
        gen.emitStoreLocal32(resultOffset + sliceInfo.capacityOffset);

        // Now safe to release temp slots
        temps.restore(mark);

        // Return address of result slice struct
        gen.emitStackAddress(resultOffset);
    }

    /**
     * Compile slice append: arr ~= element
     *
     * Native slice layout: { ptr: i64, length: i32, capacity: i32 } = sliceInfo.totalSize bytes
     *
     * Algorithm (mirrors WASM emitter):
     * 1. Evaluate element, store to temp
     * 2. Check if length >= capacity
     * 3. If needs grow: alloc new buffer, copy, update ptr/capacity
     * 4. Store element at ptr[length]
     * 5. Increment length
     */
    private void compileSliceAppend(size_t sliceOffset, Expression element, uint elemSize, bool isFloat = false) {
        bool isAggregate = (elemSize > 4 && !isFloat);
        // Allocate temp slots — unified layout for both f64 and i32 paths.
        // isFloat only controls which store/load instructions are used.
        auto mark = temps.save();
        size_t tempElement = temps.alloc(8);  // scalar value or source address for aggregates
        size_t tempNewCap  = temps.alloc(8);
        size_t tempNewPtr  = temps.alloc(8);
        size_t tempLoopIdx = temps.alloc(8);
        size_t tempLoopVal = temps.alloc(8);
        size_t tempDestAddr = isAggregate ? temps.alloc(8) : 0;

        // 1. Evaluate element value, store to temp
        compileExpression(element);
        if (isAggregate)
            gen.emitStorePtr(tempElement);  // save source address (64-bit)
        else if (isFloat)
            gen.emitStoreLocalF64(tempElement);  // d0 → temp (f64)
        else
            gen.emitStoreLocal32(tempElement);

        // 2. Load length and capacity, compare
        gen.emitLoadLocal32(sliceOffset + sliceInfo.lengthOffset);   // x0 = length
        gen.emitMoveX0ToX1();                   // x1 = length
        gen.emitLoadLocal32(sliceOffset + sliceInfo.capacityOffset);  // x0 = capacity
        // We want: if (length >= capacity) -> x0 = 1
        gen.emit(stencil_move_arg1_to_result);  // x0 = length
        gen.emitMoveX0ToX1();                   // x1 = length (save)
        gen.emitLoadLocal32(sliceOffset + sliceInfo.capacityOffset);  // x0 = capacity
        gen.emitMoveX0ToX2();                   // x2 = capacity
        gen.emit(stencil_move_arg1_to_result);  // x0 = length
        gen.emit(stencil_move_arg2_to_arg1);    // x1 = capacity
        gen.emit(stencil_ge_i32);               // x0 = (length >= capacity) ? 1 : 0

        // 3. Branch if no growth needed (x0 == 0)
        auto growLabel = gen.newLabel();
        auto noGrowLabel = gen.newLabel();
        auto doneGrowLabel = gen.newLabel();

        gen.emitBranchIfZero(noGrowLabel);      // skip grow if length < capacity

        // === GROW PATH ===
        gen.bindLabel(growLabel);

        // newCapacity = max(capacity * 2, 4)
        gen.emitLoadLocal32(sliceOffset + sliceInfo.capacityOffset);  // x0 = capacity
        gen.emitMoveX0ToX1();                   // x1 = capacity
        gen.emit(stencil_add_i32);              // x0 = capacity * 2 (capacity + capacity)
        gen.emitStoreLocal32(tempNewCap);       // save capacity * 2

        // Compare with 4: if (capacity * 2 < 4) use 4
        gen.emitImm32(stencil_load_imm32, 4);
        gen.emitMoveX0ToX1();                   // x1 = 4
        gen.emitLoadLocal32(tempNewCap);        // x0 = capacity * 2
        gen.emit(stencil_lt_i32);               // x0 = (capacity * 2 < 4) ? 1 : 0

        auto useMinCapLabel = gen.newLabel();
        auto calcAllocLabel = gen.newLabel();

        gen.emitBranchIfZero(calcAllocLabel);   // if cap*2 >= 4, use it

        // Use minimum capacity of 4
        gen.emitImm32(stencil_load_imm32, 4);
        gen.emitStoreLocal32(tempNewCap);

        gen.bindLabel(calcAllocLabel);

        // Allocate new buffer: __ctfe_alloc(newCapacity * elemSize)
        gen.emitLoadLocal32(tempNewCap);        // x0 = newCapacity
        gen.emitImm32(stencil_load_imm32, elemSize);
        gen.emitMoveX0ToX1();                   // x1 = elemSize
        gen.emitLoadLocal32(tempNewCap);        // x0 = newCapacity
        gen.emit(stencil_mul_i32);              // x0 = newCapacity * elemSize (bytes)

        // Allocate new buffer: __ctfe_alloc if available, else malloc
        ulong allocSlot = hostFunctions.getFunctionSlotAddress("__ctfe_alloc");
        if (allocSlot != 0) {
            ulong contextSlot = hostFunctions.getContextSlotAddress();
            gen.emitHostCall(allocSlot, contextSlot);  // x0 = new buffer ptr
        } else {
            emitExternalOrHostCall("malloc");  // x0 = size → x0 = ptr
        }
        gen.emitStorePtr(tempNewPtr);         // save new ptr (64-bit)

        // Copy loop: for i = 0 to length: newPtr[i] = oldPtr[i]
        gen.emitImm32(stencil_load_imm32, 0);
        gen.emitStoreLocal32(tempLoopIdx);      // i = 0

        auto copyLoopStart = gen.newLabel();
        auto copyLoopEnd = gen.newLabel();

        gen.bindLabel(copyLoopStart);

        // Check: if (i >= length) break
        gen.emitLoadLocal32(tempLoopIdx);       // x0 = i
        gen.emitMoveX0ToX1();                   // x1 = i
        gen.emitLoadLocal32(sliceOffset + sliceInfo.lengthOffset);   // x0 = length
        gen.emitMoveX0ToX2();                   // x2 = length
        gen.emit(stencil_move_arg1_to_result);  // x0 = i
        gen.emit(stencil_move_arg2_to_arg1);    // x1 = length
        gen.emit(stencil_ge_i32);               // x0 = (i >= length)
        gen.emitBranchIfNonZero(copyLoopEnd);   // break if done

        // Compute source address: oldPtr + i * elemSize → x0
        gen.emitLoadLocal32(tempLoopIdx);       // x0 = i
        gen.emitMoveX0ToX1();                   // x1 = i
        gen.emitImm32(stencil_load_imm32, elemSize);
        gen.emit(stencil_mul_i32);              // x0 = i * elemSize (note: x0=elemSize*x1 but MUL is w1*w0)
        // Fix: need i * elemSize. x0 = elemSize, x1 = i → MUL w0, w1, w0 = i * elemSize ✓
        gen.emitMoveX0ToX1();                   // x1 = i * elemSize
        gen.emitLoadPtr(sliceOffset);           // x0 = oldPtr
        gen.emit(stencil_add_i64);              // x0 = oldPtr + i*elemSize

        if (isAggregate) {
            // Source address already in x0 = oldPtr + i*elemSize
            gen.emitStorePtr(tempLoopVal);         // tempLoopVal = source addr

            // Compute dest address: newPtr + i * elemSize → tempDestAddr
            gen.emitLoadLocal32(tempLoopIdx);       // x0 = i
            gen.emitMoveX0ToX1();                   // x1 = i
            gen.emitImm32(stencil_load_imm32, elemSize);
            gen.emit(stencil_mul_i32);              // x0 = i * elemSize
            gen.emitMoveX0ToX1();                   // x1 = i * elemSize
            gen.emitLoadPtr(tempNewPtr);            // x0 = newPtr
            gen.emit(stencil_add_i64);              // x0 = newPtr + i*elemSize
            gen.emitStorePtr(tempDestAddr);         // tempDestAddr = dest addr

            // Word-by-word copy
            for (uint w = 0; w < elemSize; w += 4) {
                gen.emitLoadPtr(tempLoopVal);       // x0 = source addr
                gen.emitLoadFromPointer(w);         // x0 = word at [source + w]
                gen.emitMoveX0ToX9();               // x9 = word
                gen.emitLoadPtr(tempDestAddr);      // x0 = dest addr
                gen.emitStoreToPointerFromX9(w);    // [dest + w] = x9
            }
        } else {
            // Load element from source (scalar)
            if (isFloat) {
                gen.emit(stencil_load_f64);         // d0 = f64 at [x0]
                gen.emitStoreLocalF64(tempLoopVal); // save to temp (f64)
            } else if (elemSize == 1) {
                gen.emitLoadByteFromPointer(0);     // x0 = byte at [x0]
                gen.emitStoreLocal32(tempLoopVal);
            } else {
                gen.emitLoadFromPointer(0);         // x0 = i32 at [x0]
                gen.emitStoreLocal32(tempLoopVal);
            }

            // Compute dest address: newPtr + i * elemSize → x0
            gen.emitLoadLocal32(tempLoopIdx);       // x0 = i
            gen.emitMoveX0ToX1();                   // x1 = i
            gen.emitImm32(stencil_load_imm32, elemSize);
            gen.emit(stencil_mul_i32);              // x0 = i * elemSize
            gen.emitMoveX0ToX1();                   // x1 = i * elemSize
            gen.emitLoadPtr(tempNewPtr);            // x0 = newPtr
            gen.emit(stencil_add_i64);              // x0 = newPtr + i*elemSize

            // Store element to dest
            if (isFloat) {
                gen.emitLoadLocalF64(tempLoopVal);  // d0 = saved f64
                gen.emit(stencil_store_f64);        // STR d0, [x0]
            } else {
                gen.emitMoveX0ToX1();               // x1 = dest addr
                gen.emitLoadLocal32(tempLoopVal);   // x0 = value
                gen.emitMoveX0ToX2();               // x2 = value
                gen.emit(stencil_move_arg1_to_result);  // x0 = dest addr
                gen.emit(stencil_move_arg2_to_arg1);    // x1 = value
                if (elemSize == 1)
                    gen.emitStoreByteToPointer(0);
                else
                    gen.emit(stencil_store_i32);
            }
        }

        // i++ (compound stencil)
        gen.emitIncLocal32(tempLoopIdx);

        gen.emitBranch(copyLoopStart);
        gen.bindLabel(copyLoopEnd);

        // Update slice ptr = newPtr
        gen.emitLoadPtr(tempNewPtr);
        gen.emitStorePtr(sliceOffset);

        // Update slice capacity = newCapacity
        gen.emitLoadLocal32(tempNewCap);
        gen.emitStoreLocal32(sliceOffset + sliceInfo.capacityOffset);

        gen.emitBranch(doneGrowLabel);

        // === NO GROW PATH ===
        gen.bindLabel(noGrowLabel);

        gen.bindLabel(doneGrowLabel);

        // 4. Store element at ptr[length * elemSize]
        // Compute dest address: ptr + length * elemSize → x0
        gen.emitLoadLocal32(sliceOffset + sliceInfo.lengthOffset);   // x0 = length
        gen.emitMoveX0ToX1();                   // x1 = length
        gen.emitImm32(stencil_load_imm32, elemSize);
        gen.emit(stencil_mul_i32);              // x0 = length * elemSize
        gen.emitMoveX0ToX1();                   // x1 = length * elemSize
        gen.emitLoadPtr(sliceOffset);           // x0 = ptr
        gen.emit(stencil_add_i64);              // x0 = ptr + length*elemSize

        if (isAggregate) {
            // x0 = dest address (ptr + length*elemSize)
            gen.emitStorePtr(tempDestAddr);         // save dest addr

            // Word-by-word copy from source (tempElement) to dest (tempDestAddr)
            for (uint w = 0; w < elemSize; w += 4) {
                gen.emitLoadPtr(tempElement);       // x0 = source addr
                gen.emitLoadFromPointer(w);         // x0 = word at [source + w]
                gen.emitMoveX0ToX9();               // x9 = word
                gen.emitLoadPtr(tempDestAddr);      // x0 = dest addr
                gen.emitStoreToPointerFromX9(w);    // [dest + w] = x9
            }
        } else if (isFloat) {
            gen.emitLoadLocalF64(tempElement);  // d0 = element (f64)
            gen.emit(stencil_store_f64);        // STR d0, [x0]
        } else {
            gen.emitMoveX0ToX1();               // x1 = dest addr
            gen.emitLoadLocal32(tempElement);   // x0 = element value
            gen.emitMoveX0ToX2();               // x2 = element
            gen.emit(stencil_move_arg1_to_result);  // x0 = dest addr
            gen.emit(stencil_move_arg2_to_arg1);    // x1 = element
            if (elemSize == 1)
                gen.emitStoreByteToPointer(0);
            else
                gen.emit(stencil_store_i32);
        }

        // 5. Increment length
        gen.emitLoadLocal32(sliceOffset + sliceInfo.lengthOffset);   // x0 = length
        gen.emitMoveX0ToX1();                   // x1 = length
        gen.emitImm32(stencil_load_imm32, 1);
        gen.emitMoveX0ToX2();                   // x2 = 1
        gen.emit(stencil_move_arg1_to_result);  // x0 = length
        gen.emit(stencil_move_arg2_to_arg1);    // x1 = 1
        gen.emit(stencil_add_i32);              // x0 = length + 1
        gen.emitStoreLocal32(sliceOffset + sliceInfo.lengthOffset);  // store new length
        temps.restore(mark);
    }

    /**
     * Compile slice append for a struct field slice (implicit this.field).
     * Strategy: copy slice struct to a local temp, run compileSliceAppend on that,
     * then copy the modified slice back to the struct field.
     *
     * For the copy-back, we use a temp to save the field address (pointer-based),
     * then use emitStoreToPointer/emitStoreToPointerFromX9 for 32-bit fields,
     * and a pair of 32-bit stores for the 64-bit ptr field.
     */
    private void compileSliceFieldAppend(size_t fieldOffset, Expression element, ArrayType arrType) {
        import codegen.type_marshal : TypeReader;
        uint elemSize = TypeReader.forNative().elementSizeOf(arrType.elementType);
        const totalSize = sliceInfo.totalSize;

        // Allocate temp on frame for the slice copy
        size_t tempSlice = (nextLocalOffset + 7) & ~7;  // 8-byte aligned
        nextLocalOffset = tempSlice + totalSize;
        size_t tempFieldAddr = (nextLocalOffset + 7) & ~7;
        nextLocalOffset = tempFieldAddr + 8;

        // Helper: compute and save this_ptr + fieldOffset to tempFieldAddr
        void emitSaveFieldAddr() {
            gen.emitLoadPtr(currentThisOffset);
            if (fieldOffset > 0) {
                gen.emitMoveX0ToX1();
                gen.emitImm32(stencil_load_imm32, cast(int)fieldOffset);
                gen.emit(stencil_add_i64);
            }
            gen.emitStorePtr(tempFieldAddr);
        }

        // Copy slice from this_ptr + fieldOffset to tempSlice
        emitSaveFieldAddr();
        // ptr (8 bytes): load from [fieldAddr]
        gen.emitLoadPtr(tempFieldAddr);
        gen.emit(stencil_load_i64);
        gen.emitStorePtr(tempSlice);
        // length: load from [fieldAddr + lengthOffset]
        gen.emitLoadPtr(tempFieldAddr);
        gen.emitLoadFromPointer(sliceInfo.lengthOffset);
        gen.emitStoreLocal32(tempSlice + sliceInfo.lengthOffset);
        // capacity: load from [fieldAddr + capacityOffset]
        gen.emitLoadPtr(tempFieldAddr);
        gen.emitLoadFromPointer(sliceInfo.capacityOffset);
        gen.emitStoreLocal32(tempSlice + sliceInfo.capacityOffset);

        // Run the standard append on the temp copy
        compileSliceAppend(tempSlice, element, elemSize, isF64ElementType(arrType.elementType));

        // Copy modified slice back to this_ptr + fieldOffset
        emitSaveFieldAddr();
        // ptr: store 64-bit using two 32-bit stores (low word at +0, high word at +4)
        gen.emitLoadLocal32(tempSlice);  // x0 = low 32 bits of ptr
        gen.emitMoveX0ToX1();
        gen.emitLoadPtr(tempFieldAddr);
        gen.emitStoreToPointer(0);  // STR w1, [x0, #0]
        gen.emitLoadLocal32(tempSlice + 4);  // x0 = high 32 bits of ptr
        gen.emitMoveX0ToX1();
        gen.emitLoadPtr(tempFieldAddr);
        gen.emitStoreToPointer(4);  // STR w1, [x0, #4]
        // length
        gen.emitLoadLocal32(tempSlice + sliceInfo.lengthOffset);
        gen.emitMoveX0ToX1();
        gen.emitLoadPtr(tempFieldAddr);
        gen.emitStoreToPointer(sliceInfo.lengthOffset);
        // capacity
        gen.emitLoadLocal32(tempSlice + sliceInfo.capacityOffset);
        gen.emitMoveX0ToX1();
        gen.emitLoadPtr(tempFieldAddr);
        gen.emitStoreToPointer(sliceInfo.capacityOffset);
    }

    /**
     * Compile slice append for a local struct's field slice: localStruct.field ~= value
     * Strategy: same copy-to-temp approach, using known frame offsets for the struct.
     */
    private void compileSliceFieldAppendLocal(size_t structOffset, size_t fieldOffset, Expression element, ArrayType arrType) {
        import codegen.type_marshal : TypeReader;
        uint elemSize = TypeReader.forNative().elementSizeOf(arrType.elementType);
        const totalSize = sliceInfo.totalSize;
        size_t sliceAddr = structOffset + fieldOffset;

        // Allocate temp on frame
        size_t tempSlice = (nextLocalOffset + 7) & ~7;
        nextLocalOffset = tempSlice + totalSize;

        // Copy slice from structOffset + fieldOffset to tempSlice
        // For local structs, we can use stack-relative addressing
        // ptr (8 bytes)
        gen.emitStackAddress(sliceAddr);  // x0 = address of slice in struct
        gen.emit(stencil_load_i64);  // x0 = slice.ptr
        gen.emitStorePtr(tempSlice);
        // length
        gen.emitStackAddress(sliceAddr);
        gen.emitLoadFromPointer(sliceInfo.lengthOffset);
        gen.emitStoreLocal32(tempSlice + sliceInfo.lengthOffset);
        // capacity
        gen.emitStackAddress(sliceAddr);
        gen.emitLoadFromPointer(sliceInfo.capacityOffset);
        gen.emitStoreLocal32(tempSlice + sliceInfo.capacityOffset);

        // Run append on temp
        compileSliceAppend(tempSlice, element, elemSize, isF64ElementType(arrType.elementType));

        // Copy back: use stack-address approach (safe even if sliceAddr is not 8-byte aligned)
        auto mark = temps.save();
        size_t addrTemp = temps.alloc(8);
        // Save slice field address
        gen.emitStackAddress(sliceAddr);
        gen.emitStorePtr(addrTemp);
        // ptr: copy low and high 32 bits separately
        gen.emitLoadLocal32(tempSlice);  // low 32 bits of ptr
        gen.emitMoveX0ToX1();
        gen.emitLoadPtr(addrTemp);
        gen.emitStoreToPointer(0);
        gen.emitLoadLocal32(tempSlice + 4);  // high 32 bits of ptr
        gen.emitMoveX0ToX1();
        gen.emitLoadPtr(addrTemp);
        gen.emitStoreToPointer(4);
        // length
        gen.emitLoadLocal32(tempSlice + sliceInfo.lengthOffset);
        gen.emitMoveX0ToX1();
        gen.emitLoadPtr(addrTemp);
        gen.emitStoreToPointer(sliceInfo.lengthOffset);
        // capacity
        gen.emitLoadLocal32(tempSlice + sliceInfo.capacityOffset);
        gen.emitMoveX0ToX1();
        gen.emitLoadPtr(addrTemp);
        gen.emitStoreToPointer(sliceInfo.capacityOffset);
        temps.restore(mark);
    }

    /**
     * Compile __writeln(args...) by lowering to typed host function calls.
     * Milestone 89: Native __writeln support.
     */
    /**
     * Emit a compiler intrinsic — raw opcodes, no function call.
     */
    private void compileIntrinsicCall(string name, Expression[] args) {
        if (name == "__intrinsic_shl") {
            assert(args.length == 2, "__intrinsic_shl requires 2 arguments");
            compileExpression(args[1]);
            gen.emitMoveX0ToX1();
            compileExpression(args[0]);
            gen.emit(stencil_shl_i32);
        } else if (name == "__intrinsic_shr_s") {
            assert(args.length == 2, "__intrinsic_shr_s requires 2 arguments");
            compileExpression(args[1]);
            gen.emitMoveX0ToX1();
            compileExpression(args[0]);
            gen.emit(stencil_shr_i32);
        } else if (name == "__intrinsic_shr_u") {
            assert(args.length == 2, "__intrinsic_shr_u requires 2 arguments");
            compileExpression(args[1]);
            gen.emitMoveX0ToX1();
            compileExpression(args[0]);
            gen.emit(stencil_lsr_i32);  // unsigned (logical) shift right
        } else if (name == "__intrinsic_unreachable") {
            // BRK #1 — triggers SIGTRAP
            gen.emitRaw32(0xD4200020);
        } else {
            throw new Exception("Unknown intrinsic: " ~ name);
        }
    }

    private void compileWriteln(Expression[] args) {
        foreach (arg; args) {
            if (auto literal = cast(LiteralExpression)arg) {
                if (literal.value.type == typeid(string)) {
                    string strVal = literal.value.get!string();
                    if (objectMode) {
                        emitWriteString(strVal);
                    } else {
                        // JIT: use host function for string output
                        ubyte* strPtr = dataSection.addString(strVal);
                        gen.emitLoadImm64(cast(ulong)strPtr);
                        gen.emitMoveX0ToX1();
                        gen.emitImm32(stencil_load_imm32, cast(int)strVal.length);
                        gen.emitMoveX0ToX2();
                        gen.emitMoveX1ToX0();
                        gen.emitMoveX2ToX1();
                        ulong slot = hostFunctions.getFunctionSlotAddress("__ctfe_write_str");
                        ulong ctxSlot = hostFunctions.getContextSlotAddress();
                        gen.emitHostCall(slot, ctxSlot);
                    }
                }
                else if (literal.value.type == typeid(long) || literal.value.type == typeid(int)) {
                    long val = literal.value.type == typeid(long)
                        ? literal.value.get!long()
                        : literal.value.get!int();
                    if (objectMode) {
                        import std.conv : to;
                        emitWriteString(to!string(val));
                    } else {
                        gen.emitImm32(stencil_load_imm32, cast(int)val);
                        ulong slot = hostFunctions.getFunctionSlotAddress("__ctfe_write_i32");
                        ulong ctxSlot = hostFunctions.getContextSlotAddress();
                        gen.emitHostCall(slot, ctxSlot);
                    }
                }
                else if (literal.value.type == typeid(bool)) {
                    bool val = literal.value.get!bool();
                    if (objectMode) {
                        emitWriteString(val ? "true" : "false");
                    } else {
                        gen.emitImm32(stencil_load_imm32, val ? 1 : 0);
                        ulong slot = hostFunctions.getFunctionSlotAddress("__ctfe_write_bool");
                        ulong ctxSlot = hostFunctions.getContextSlotAddress();
                        gen.emitHostCall(slot, ctxSlot);
                    }
                }
            }
            else {
                // Non-literal expression: evaluate and print
                compileExpression(arg);
                if (objectMode) {
                    // Object mode: no host functions, write placeholder
                    // TODO: implement runtime itoa for proper integer output
                    emitWriteString("<val>");
                } else {
                    ulong slot = hostFunctions.getFunctionSlotAddress("__ctfe_write_i32");
                    ulong ctxSlot = hostFunctions.getContextSlotAddress();
                    gen.emitHostCall(slot, ctxSlot);
                }
            }
        }

        // Emit newline
        if (objectMode) {
            emitWriteString("\n");
        } else {
            ulong newlineSlot = hostFunctions.getFunctionSlotAddress("__ctfe_write_newline");
            ulong ctxSlot = hostFunctions.getContextSlotAddress();
            gen.emitHostCall(newlineSlot, ctxSlot);
        }
    }

    /// Emit write(1, str, len) to stdout for a compile-time string.
    /// Works in both JIT and object mode.
    private void emitWriteString(string str) {
        // Store string data and load address into x0
        emitStringLoad(str);
        // Set up write(1, buf, len): x0=fd, x1=buf, x2=len
        gen.emitMoveX0ToX1();                  // x1 = buf pointer
        gen.emitLoadImm(cast(int)str.length);  // x0 = len
        gen.emitMoveX0ToX2();                  // x2 = len
        gen.emitLoadImm(1);                    // x0 = 1 (stdout)
        emitExternalOrHostCall("write");
    }
    
    /**
     * Check if an expression contains a function call (for register clobber detection)
     */
    private bool containsCall(Expression expr) {
        if (cast(CallExpression)expr) return true;
        
        if (auto binOp = cast(BinaryExpression)expr) {
            return containsCall(binOp.left) || containsCall(binOp.right);
        }
        if (auto unaryOp = cast(UnaryExpression)expr) {
            return containsCall(unaryOp.operand);
        }
        if (auto indexExpr = cast(IndexExpression)expr) {
            return containsCall(indexExpr.array) || containsCall(indexExpr.index);
        }
        if (auto memberExpr = cast(MemberExpression)expr) {
            return containsCall(memberExpr.object);
        }
        if (auto castExpr = cast(CastExpression)expr) {
            return containsCall(castExpr.expression);
        }
        return false;
    }
    
    /**
     * Compile struct field assignment: obj.field = value
     */
    private void compileMemberAssignment(MemberExpression member, AssignmentExpression assign) {
        AggregateDecl aggregateDecl = getAggregateDeclFromExpr(member.object);
        if (aggregateDecl is null)
            throw new NativeCompileError("Cannot determine struct/class type for member assignment", assign.location);

        auto field = aggregateDecl.getField(member.memberName);
        if (field is null)
            throw new NativeCompileError("Unknown field '" ~ member.memberName ~ "' on " ~ aggregateDecl.name, assign.location);

        // Local struct/class variable
        if (auto ident = cast(IdentifierExpression)member.object) {
            if (auto varInfo = ident.name in localVars) {
                if (varInfo.isReference) {
                    // Reference (class param / this): dereference pointer, then store
                    compileExpression(assign.right);
                    gen.emitMoveX0ToX9();
                    gen.emitLoadPtr(varInfo.offset);  // x0 = pointer to instance
                    gen.emitStoreToPointerFromX9(field.offset);
                } else {
                    // Direct instance on stack
                    compileExpression(assign.right);
                    gen.emitStoreLocal32(varInfo.offset + field.offset);
                }
                return;
            }
        }

        // Pointer-based target (nested access, index, etc.)
        compileExpression(assign.right);
        gen.emitMoveX0ToX9();
        compileExpression(member.object);
        gen.emitStoreToPointerFromX9(field.offset);
    }

    // ---- UFCS (Uniform Function Call Syntax) ----

    /// Emit a UFCS call: obj.func(args...) → func(obj, args...)
    /// The object becomes the first argument to the free function.
    private void emitUFCSCall(MemberExpression memberExpr, Expression[] args) {
        log(2, "native: UFCS call .", memberExpr.memberName, " with ", args.length, " extra args");
        // Build combined argument list: [object, args...]
        Expression[] allArgs = [memberExpr.object] ~ args;

        // Look up the function by name
        string funcName = memberExpr.memberName;
        auto symbol = symbolTable.lookupSymbol(funcName);
        FunctionDecl funcDecl;
        if (symbol && symbol.kind == SymbolKind.Function)
            funcDecl = cast(FunctionDecl)symbol.declaration;

        string callName = funcName;
        if (funcDecl) {
            callName = getMangledName(funcDecl);
        }

        auto labelPtr = callName in functionLabels;
        if (labelPtr is null)
            throw new Exception("UFCS function not compiled: " ~ callName);

        bool calleeNeedsArena = false;
        if (auto calleeDecl = callName in functionDecls)
            calleeNeedsArena = (*calleeDecl).needsArena;
        int arenaShift = calleeNeedsArena ? 1 : 0;

        // Compile and save args to temp slots
        auto mark = temps.save();
        size_t[] argTemps;
        foreach (arg; allArgs) {
            compileExpression(arg);
            size_t t = temps.alloc(8);
            gen.emitStorePtr(t);
            argTemps ~= t;
        }

        // Load args into registers (shifted by arena)
        for (long i = cast(long)argTemps.length - 1; i >= 0; i--) {
            gen.emitLoadPtr(argTemps[cast(size_t)i]);
            switch (cast(int)i + arenaShift) {
                case 0: break;  // already in x0
                case 1: gen.emitMoveX0ToX1(); break;
                case 2: gen.emitMoveX0ToX2(); break;
                case 3: gen.emitMoveX0ToX3(); break;
                default: assert(0, "UFCS: too many arguments");
            }
        }

        // Load arena into x0 if callee needs it (user args already shifted to x1+)
        if (calleeNeedsArena) {
            gen.emitLoadPtr(currentFunctionArenaOffset);
        }

        gen.emitCall(*labelPtr);
        emitNativeExceptionCheck();
        temps.restore(mark);
    }

    // ---- ObjC runtime dispatch (objc_msgSend) ----

    /// Find ObjC method in interface by name
    private FunctionDecl findObjCMethod(FunctionDecl[] methods, string name) {
        foreach (m; methods) {
            if (m.name == name) return m;
        }
        return null;
    }

    /// Store a null-terminated C string in the data section and load its address into x0.
    private void emitCStringLoad(string s) {
        auto bytes = cast(const(ubyte)[])(s ~ '\0');
        emitDataLoad(bytes, "__cstr_");
    }

    /// Emit an ObjC method call via objc_msgSend for an InterfaceDecl.
    private void emitObjCCall(InterfaceDecl ifaceDecl, Expression receiver,
            string methodName, Expression[] args, bool isStatic) {
        // Find the method to get its selector
        auto method = findObjCMethod(ifaceDecl.methods, methodName);
        if (method is null)
            throw new Exception("ObjC interface '" ~ ifaceDecl.name ~ "' has no method '" ~ methodName ~ "'");

        string selector = method.objcSelector;
        if (selector is null || selector.length == 0)
            selector = method.name;

        emitObjCMsgSend(ifaceDecl.name, selector, receiver, args, isStatic);
    }

    /// Emit an ObjC method call via objc_msgSend for a ClassDecl.
    private void emitObjCCallFromClass(ClassDecl classDecl, Expression receiver,
            string methodName, Expression[] args, bool isStatic) {
        // Search class members for the method
        string selector = methodName;
        FunctionDecl dBodyMethod = null;
        foreach (member; classDecl.members) {
            if (auto funcDecl = cast(FunctionDecl)member) {
                if (funcDecl.name == methodName) {
                    if (funcDecl.body_ !is null)
                        dBodyMethod = funcDecl;  // Has D implementation
                    if (funcDecl.objcSelector !is null && funcDecl.objcSelector.length > 0)
                        selector = funcDecl.objcSelector;
                    break;
                }
            }
        }
        // Also check parent ObjC interface/class
        if (classDecl.baseClassDecl && classDecl.baseClassDecl.isObjC) {
            foreach (member; classDecl.baseClassDecl.members) {
                if (auto funcDecl = cast(FunctionDecl)member) {
                    if (funcDecl.name == methodName) {
                        if (funcDecl.objcSelector !is null && funcDecl.objcSelector.length > 0)
                            selector = funcDecl.objcSelector;
                        break;
                    }
                }
            }
        }

        // If method has a D body, call it directly instead of through objc_msgSend
        if (dBodyMethod !is null) {
            string mangledName = getMangledName(dBodyMethod);
            auto labelPtr = mangledName in functionLabels;
            log(2, "native: ObjC D-body method '", methodName, "' mangled='", mangledName, "' found=", labelPtr !is null);
            if (labelPtr !is null) {
                // Direct call: x0 = this (receiver)
                if (receiver !is null)
                    compileExpression(receiver);
                gen.emitCall(*labelPtr);
                emitNativeExceptionCheckWithValue();
                return;
            }
        }

        emitObjCMsgSend(classDecl.name, selector, receiver, args, isStatic);
    }

    /// Core objc_msgSend emission.
    /// ARM64 calling convention: objc_msgSend(id self, SEL _cmd, ...args)
    ///   x0 = receiver (self), x1 = selector (_cmd), x2+ = user args
    private void emitObjCMsgSend(string className, string selector,
            Expression receiver, Expression[] args, bool isStatic) {
        auto mark = temps.save();
        size_t receiverTemp = temps.alloc(8);
        size_t selectorTemp = temps.alloc(8);

        // Step 1: Get receiver and save to temp
        if (isStatic) {
            // Static call: objc_getClass("ClassName") → x0 = Class pointer
            emitCStringLoad(className);
            emitExternalOrHostCall("objc_getClass");
        } else {
            // Instance call: compile receiver expression
            compileExpression(receiver);
        }
        gen.emitStorePtr(receiverTemp);

        // Step 2: sel_registerName("selector") → x0 = SEL, save to temp
        emitCStringLoad(selector);
        emitExternalOrHostCall("sel_registerName");
        gen.emitStorePtr(selectorTemp);

        // Step 3: User args in x2, x3, ...
        if (args.length > 2)
            throw new Exception("ObjC calls with more than 2 user arguments not yet supported");
        // Compile args and save to temps, then load into registers
        size_t[] argTemps;
        foreach (arg; args) {
            compileExpression(arg);
            size_t t = temps.alloc(8);
            gen.emitStorePtr(t);
            argTemps ~= t;
        }

        // Load args into x2, x3
        foreach (i, t; argTemps) {
            gen.emitLoadPtr(t);
            switch (cast(int)i) {
                case 0: gen.emitMoveX0ToX2(); break;
                case 1: gen.emitMoveX0ToX3(); break;
                default: break;
            }
        }

        // Step 4: x1 = SEL
        gen.emitLoadPtr(selectorTemp);
        gen.emitMoveX0ToX1();

        // Step 5: x0 = receiver
        gen.emitLoadPtr(receiverTemp);

        // Step 6: Call objc_msgSend
        emitExternalOrHostCall("objc_msgSend");

        temps.restore(mark);
        // Result is in x0
    }

    /// Emit a call to a runtime function resolved via dlsym (JIT mode only).
    private void emitJITExternalCall(string funcName) {
        // Resolve via dlsym at compile time, call via indirect x9
        import core.sys.posix.dlfcn : dlsym;
        version (OSX) {
            import core.sys.darwin.dlfcn : RTLD_DEFAULT;
        } else {
            import core.sys.posix.dlfcn : RTLD_DEFAULT;
        }
        auto ptr = dlsym(RTLD_DEFAULT, (funcName ~ '\0').ptr);
        if (ptr is null)
            throw new Exception("Cannot resolve runtime function: " ~ funcName);
        gen.emitLoadImm64ToX9(cast(ulong)cast(size_t)ptr);
        gen.emitCallIndirectX9();
    }

    // ---- Vtable infrastructure for class virtual dispatch ----

    /// Ensure virtualMethods is populated for the class and its base chain.
    private void computeVirtualMethodsIfNeeded(ClassDecl classDecl) {
        if (classDecl.virtualMethods.length > 0) return;
        log(2, "native: computeVirtualMethods for ", classDecl.name);

        if (classDecl.baseClassDecl) {
            computeVirtualMethodsIfNeeded(classDecl.baseClassDecl);
            classDecl.virtualMethods = classDecl.baseClassDecl.virtualMethods.dup;
        } else {
            classDecl.virtualMethods = [];
        }

        foreach (member; classDecl.members) {
            if (auto funcDecl = cast(FunctionDecl)member) {
                if (funcDecl.isMethod && !funcDecl.isConstructor && !funcDecl.isDestructor) {
                    import std.algorithm : countUntil;
                    auto overrideIdx = classDecl.virtualMethods.countUntil!(
                        m => m.name == funcDecl.name
                    );
                    if (overrideIdx >= 0) {
                        classDecl.virtualMethods[overrideIdx] = funcDecl;
                    } else {
                        classDecl.virtualMethods ~= funcDecl;
                    }
                }
            }
        }
    }

    /// Ensure a class has a native vtable allocated. Idempotent.
    private void ensureNativeVtable(ClassDecl classDecl) {
        assert(classDecl !is null, "ensureNativeVtable: null ClassDecl");
        if (classDecl.name in classTableBases) return; // already set up
        log(2, "native: ensureNativeVtable ", classDecl.name);

        // Ensure base class has vtable first
        if (classDecl.baseClassDecl)
            ensureNativeVtable(classDecl.baseClassDecl);

        computeVirtualMethodsIfNeeded(classDecl);

        uint tableBase = nextNativeTableBase;
        uint slotCount = cast(uint)classDecl.virtualMethods.length;
        classTableBases[classDecl.name] = tableBase;
        nextNativeTableBase += slotCount;

        // Extend vtableMethodNames to cover new slots
        while (vtableMethodNames.length < tableBase + slotCount)
            vtableMethodNames ~= null;

        if (objectMode) {
            // Object mode: allocate vtable slots in objectData with relocations
            if (vtableStartOffset == size_t.max && slotCount > 0) {
                vtableStartOffset = cast(size_t)objectData.length;
                // Register __vtable symbol at the start of vtable data
                objectDataSymbols ~= ObjectDataSymbol("__vtable", cast(uint)vtableStartOffset);
            }

            foreach (i, method; classDecl.virtualMethods) {
                string mangledName = getMangledName(method);
                vtableMethodNames[tableBase + i] = mangledName;

                // Allocate 8-byte slot in object data (zero-filled, linker patches via relocation)
                uint slotOff = appendObjectData(new ubyte[8]);
                // Add relocation: data section offset -> text symbol (linker resolves address)
                objectRelocations ~= ObjectReloc(slotOff, mangledName, RelocType.unsigned64, 1);
            }
        } else {
            // JIT mode: allocate vtable slots in data section (patched after finalize)
            if (vtableStartOffset == size_t.max && slotCount > 0)
                vtableStartOffset = dataSection.bytesUsed;

            foreach (i, method; classDecl.virtualMethods) {
                string mangledName = getMangledName(method);
                vtableMethodNames[tableBase + i] = mangledName;

                // Allocate 8 bytes in data section (will be patched after finalize)
                ubyte[8] zero = 0;
                dataSection.addData(zero[]);
            }
        }
    }

    /// After gen.finalize(), patch vtable entries with actual function addresses.
    private void patchVtableEntries() {
        if (vtableStartOffset == size_t.max) return; // no vtables

        log(2, "native: patchVtableEntries: ", vtableMethodNames.length, " slots, vtableStartOffset=", vtableStartOffset);
        foreach (slotIdx, mangledName; vtableMethodNames) {
            if (mangledName is null || mangledName.length == 0) continue;
            auto labelPtr = mangledName in functionLabels;
            if (labelPtr is null)
                throw new Exception("vtable slot " ~ mangledName ~ " has no compiled function label");
            ulong funcAddr = cast(ulong)(cast(size_t)gen.base + (*labelPtr).offset);
            size_t slotOffset = vtableStartOffset + slotIdx * 8;
            *cast(ulong*)(dataSection.base + slotOffset) = funcAddr;
            log(2, "native:   vtable[", slotIdx, "] = ", mangledName, " -> addr ", funcAddr);
        }
    }

    // ---- End vtable infrastructure ----

    /**
     * Get the StructDecl from an expression (for member access type resolution)
     */
    private StructDecl getStructDeclFromExpr(Expression expr) {
        // For identifier expressions, check our local struct types first
        if (auto ident = cast(IdentifierExpression)expr) {
            // Check local variables
            if (auto info = ident.name in localVars) {
                if (info.isStruct) return info.structDecl;
            }
            // Fall back to symbol table
            auto symbol = symbolTable.lookupSymbol(ident.name);
            if (symbol) {
                return symbol.type.asStruct();
            }
        }
        // For member expressions (nested struct access like o.inner),
        // get the struct type of the field
        if (auto member = cast(MemberExpression)expr) {
            // First get the struct decl of the base object
            auto baseDecl = getStructDeclFromExpr(member.object);
            if (baseDecl !is null) {
                // Find the field and check if it's a struct type
                auto field = baseDecl.getField(member.memberName);
                if (field !is null) {
                    return field.type.asStruct();
                }
            }
        }
        // For index expressions (array element access), get element struct type
        if (auto indexExpr = cast(IndexExpression)expr) {
            if (auto ident = cast(IdentifierExpression)indexExpr.array) {
                if (auto info = ident.name in localVars) {
                    if (info.elementType)
                        return info.elementType.asStruct();
                }
            }
        }
        // For call expressions (struct construction), get the struct type
        if (auto call = cast(CallExpression)expr) {
            if (auto funcIdent = cast(IdentifierExpression)call.function_) {
                auto symbol = symbolTable.lookupSymbol(funcIdent.name);
                if (symbol && symbol.kind == SymbolKind.Type) {
                    return symbol.type.asStruct();
                }
            }
        }
        return null;
    }

    /// Get ClassDecl from an expression (parallel to getStructDeclFromExpr).
    private ClassDecl getClassDeclFromExpr(Expression expr) {
        if (auto ident = cast(IdentifierExpression)expr) {
            if (auto info = ident.name in localVars) {
                if (info.isClass) return info.classDecl;
            }
            auto symbol = symbolTable.lookupSymbol(ident.name);
            if (symbol) {
                return symbol.type.asClass();
            }
        }
        if (auto member = cast(MemberExpression)expr) {
            // Check if the base is a class/struct with a class-typed field
            auto baseClassDecl = getClassDeclFromExpr(member.object);
            if (baseClassDecl !is null) {
                auto field = baseClassDecl.getField(member.memberName);
                if (field !is null)
                    return field.type.asClass();
            }
            auto baseStructDecl = getStructDeclFromExpr(member.object);
            if (baseStructDecl !is null) {
                auto field = baseStructDecl.getField(member.memberName);
                if (field !is null)
                    return field.type.asClass();
            }
        }
        return null;
    }

    /// Get the aggregate declaration (struct or class) from an expression.
    private AggregateDecl getAggregateDeclFromExpr(Expression expr) {
        if (auto sd = getStructDeclFromExpr(expr))
            return cast(AggregateDecl)sd;
        if (auto cd = getClassDeclFromExpr(expr))
            return cast(AggregateDecl)cd;
        return null;
    }

    /// Read uncaught exception from the native exception slot stack.
    private ExecutionResult readNativeUncaughtException() {
        import codegen.backend : CallStackFrame;
        import codegen.error_kind : ErrorKind, errorKindMessage;
        import codegen.native.codegen_interface : CallFrame;

        int depth = *cast(int*)exceptionDepthAddr;
        if (depth <= 0)
            return ExecutionResult.failure("uncaught exception (unknown)");

        // Read slot[depth - 1]
        ubyte* slotAddr = exceptionSlotsAddr + (depth - 1) * 24;
        uint kind = *cast(uint*)(slotAddr + 0);
        int line = *cast(int*)(slotAddr + 12);
        int col = *cast(int*)(slotAddr + 16);
        int value = *cast(int*)(slotAddr + 20);

        string msg = errorKindMessage(cast(ErrorKind)kind);
        if (cast(ErrorKind)kind == ErrorKind.UserThrow) {
            msg ~= " (thrown value: " ~ to!string(value) ~ ")";
        }

        auto r = ExecutionResult.failure(msg, "", line, col);

        // Read call stack frames from inline stack in data section
        if (dataSection.stackReserved) {
            auto frames = dataSection.getInlineCallStack();
            foreach (f; frames)
                r.callStack ~= CallStackFrame(f.funcName, f.fileName, f.line, 0);
        }
        return r;
    }

    /// Build structured failure result from a native trap (div-by-zero, null deref, etc.)
    private ExecutionResult buildTrapResult(NativeCTFEContext* ctx) {
        import codegen.backend : CallStackFrame;
        import codegen.native.codegen_interface : CallFrame;

        string msg = ctfeErrorMessage(ctx.errorKind);
        string errFile;
        int errLine, errCol;

        if (ctx.errorLoc.line > 0) {
            errFile = ctx.errorLoc.fileName;
            errLine = cast(int)ctx.errorLoc.line;
            errCol = cast(int)ctx.errorLoc.column;
        }

        auto r = ExecutionResult.failure(msg, errFile, errLine, errCol);

        // Read call stack frames (prefer inline stack from data section)
        CallFrame[] frames;
        if (ctx.dataSection !is null && ctx.dataSection.stackReserved) {
            frames = ctx.dataSection.getInlineCallStack();
        }
        if (frames.length == 0) {
            frames = ctx.callStack;
        }
        foreach (f; frames) {
            r.callStack ~= CallStackFrame(f.funcName, f.fileName, f.line, 0);
        }
        return r;
    }

    override ExecutionResult call(long[] args) {
        import codegen.native.codegen_interface : setjmp;

        // Set up execution context for host functions
        NativeCTFEContext ctx;
        ctx.dataSection = &dataSection;
        ctx.errorKind = CTFEErrorKind.None;
        hostFunctions.setContext(&ctx);
        scope(exit) hostFunctions.setContext(null);

        // Set up error recovery point - longjmp returns here on trap
        if (setjmp(ctx.errorJump) != 0) {
            // Got here via longjmp - error occurred
            return buildTrapResult(&ctx);
        }

        // Prepend arena (0) if entry function needs it (native uses __ctfe_alloc, not arena)
        long[] fullArgs;
        if (entryNeedsArena) fullArgs ~= 0L;
        fullArgs ~= args;

        // Call the compiled function with appropriate number of arguments
        // ARM64 calling convention: first 8 args in x0-x7
        long result;

        switch (fullArgs.length) {
            case 0:
                alias Fn0 = extern(C) long function();
                result = (cast(Fn0)(gen.base + entryPoint))();
                break;
            case 1:
                alias Fn1 = extern(C) long function(long);
                result = (cast(Fn1)(gen.base + entryPoint))(fullArgs[0]);
                break;
            case 2:
                alias Fn2 = extern(C) long function(long, long);
                result = (cast(Fn2)(gen.base + entryPoint))(fullArgs[0], fullArgs[1]);
                break;
            case 3:
                alias Fn3 = extern(C) long function(long, long, long);
                result = (cast(Fn3)(gen.base + entryPoint))(fullArgs[0], fullArgs[1], fullArgs[2]);
                break;
            case 4:
                alias Fn4 = extern(C) long function(long, long, long, long);
                result = (cast(Fn4)(gen.base + entryPoint))(fullArgs[0], fullArgs[1], fullArgs[2], fullArgs[3]);
                break;
            default:
                throw new Exception("Native backend: too many parameters (max 4 for now)");
        }

        if (exceptionPendingAddr !is null && *cast(int*)exceptionPendingAddr != 0)
            return readNativeUncaughtException();
        return ExecutionResult.fromInt(cast(int)result);  // Sign-extend 32-bit to 64-bit
    }

    override ExecutionResult callByName(string targetFuncName, long[] args) {
        import codegen.native.codegen_interface : setjmp;

        // Set up execution context for host functions
        NativeCTFEContext ctx;
        ctx.dataSection = &dataSection;
        ctx.errorKind = CTFEErrorKind.None;
        hostFunctions.setContext(&ctx);
        scope(exit) hostFunctions.setContext(null);

        // Look up function entry point and param count
        auto labelPtr = targetFuncName in functionLabels;
        if (labelPtr is null) {
            return ExecutionResult.failure("Function not found: " ~ targetFuncName);
        }

        auto funcDeclPtr = targetFuncName in functionDecls;
        if (funcDeclPtr is null) {
            return ExecutionResult.failure("Function decl not found: " ~ targetFuncName);
        }

        size_t targetEntry = (*labelPtr).offset;
        bool needsArena = (*funcDeclPtr).needsArena;

        // Set up error recovery point - longjmp returns here on trap
        if (setjmp(ctx.errorJump) != 0) {
            // Got here via longjmp - error occurred
            return buildTrapResult(&ctx);
        }

        // Prepend arena (0) if target function needs it
        long[] fullArgs;
        if (needsArena) fullArgs ~= 0L;
        fullArgs ~= args;

        // Call with the target function's entry point
        long result;
        switch (fullArgs.length) {
            case 0:
                alias Fn0 = extern(C) long function();
                result = (cast(Fn0)(gen.base + targetEntry))();
                break;
            case 1:
                alias Fn1 = extern(C) long function(long);
                result = (cast(Fn1)(gen.base + targetEntry))(fullArgs[0]);
                break;
            case 2:
                alias Fn2 = extern(C) long function(long, long);
                result = (cast(Fn2)(gen.base + targetEntry))(fullArgs[0], fullArgs[1]);
                break;
            case 3:
                alias Fn3 = extern(C) long function(long, long, long);
                result = (cast(Fn3)(gen.base + targetEntry))(fullArgs[0], fullArgs[1], fullArgs[2]);
                break;
            case 4:
                alias Fn4 = extern(C) long function(long, long, long, long);
                result = (cast(Fn4)(gen.base + targetEntry))(fullArgs[0], fullArgs[1], fullArgs[2], fullArgs[3]);
                break;
            default:
                return ExecutionResult.failure("Too many parameters (max 4)");
        }

        if (exceptionPendingAddr !is null && *cast(int*)exceptionPendingAddr != 0)
            return readNativeUncaughtException();
        return ExecutionResult.fromInt(cast(int)result);  // Sign-extend 32-bit to 64-bit
    }

    override ExecutionResult callWithLargeReturn(string targetFuncName, long[] args, uint resultSize) {
        import codegen.native.codegen_interface : setjmp;
        import core.stdc.stdlib : malloc, free;

        // Allocate buffer for result
        ubyte* resultBuf = cast(ubyte*)malloc(resultSize);
        if (resultBuf is null) {
            return ExecutionResult.failure("Failed to allocate result buffer");
        }
        scope(exit) free(resultBuf);

        // Set up execution context for host functions
        NativeCTFEContext ctx;
        ctx.dataSection = &dataSection;
        ctx.errorKind = CTFEErrorKind.None;
        hostFunctions.setContext(&ctx);
        scope(exit) hostFunctions.setContext(null);

        // Look up function entry point
        auto labelPtr = targetFuncName in functionLabels;
        if (labelPtr is null) {
            return ExecutionResult.failure("Function not found: " ~ targetFuncName);
        }

        // Check if target needs arena
        bool needsArena = false;
        if (auto funcDeclPtr = targetFuncName in functionDecls) {
            needsArena = (*funcDeclPtr).needsArena;
        }

        size_t targetEntry = (*labelPtr).offset;

        // Set up error recovery point
        if (setjmp(ctx.errorJump) != 0) {
            return buildTrapResult(&ctx);
        }

        // Prepend result pointer, then arena (0) if needed, then user args
        long[] fullArgs;
        fullArgs ~= cast(long)resultBuf;
        if (needsArena) fullArgs ~= 0L;
        fullArgs ~= args;

        // Call function (void return, writes to resultBuf)
        switch (fullArgs.length) {
            case 1:
                alias Fn1 = extern(C) void function(long);
                (cast(Fn1)(gen.base + targetEntry))(fullArgs[0]);
                break;
            case 2:
                alias Fn2 = extern(C) void function(long, long);
                (cast(Fn2)(gen.base + targetEntry))(fullArgs[0], fullArgs[1]);
                break;
            case 3:
                alias Fn3 = extern(C) void function(long, long, long);
                (cast(Fn3)(gen.base + targetEntry))(fullArgs[0], fullArgs[1], fullArgs[2]);
                break;
            case 4:
                alias Fn4 = extern(C) void function(long, long, long, long);
                (cast(Fn4)(gen.base + targetEntry))(fullArgs[0], fullArgs[1], fullArgs[2], fullArgs[3]);
                break;
            default:
                return ExecutionResult.failure("Too many parameters (max 4)");
        }

        if (exceptionPendingAddr !is null && *cast(int*)exceptionPendingAddr != 0)
            return readNativeUncaughtException();

        // Copy result bytes
        ubyte[] resultBytes = resultBuf[0 .. resultSize].dup;

        return ExecutionResult.fromArray(resultBytes);
    }

    override ubyte[] readMemory(ulong offset, uint length) {
        assert(offset != 0, "readMemory: null pointer dereference");
        auto ptr = cast(ubyte*)cast(size_t)offset;
        return ptr[0 .. length].dup;
    }

    override bool hasFunction(string targetFuncName) {
        return (targetFuncName in functionLabels) !is null;
    }

    override void dispose() {
        if (gen.base) {
            gen.freeBuffer();
        }
        if (dataSection.base) {
            dataSection.free();
        }
    }
    
    override string name() { return funcName; }
}

/**
 * WASM Backend - wraps the existing BinaryEmitter and CTFERuntime
 */
