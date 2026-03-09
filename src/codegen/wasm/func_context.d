/**
 * WASM Function Context
 * 
 * Handles emission of function bodies, including:
 * - Local variable management
 * - Shadow stack for structs/slices
 * - Statement emission
 * - Expression emission
 */
module codegen.wasm.func_context;

import codegen.wasm.types;
import codegen.emitter : BinaryEmitter, FuncInfo, EmitError;
import codegen.target : WasmFatPointerLayout, WasmVtablePacking, sliceLayout = sliceInfo;
import ast.nodes;
import ast.statements;
import ast.expressions;
import semantic.symbol_table;

import std.array : Appender;
import std.algorithm : map, canFind;
import std.conv : to;
import std.format : format;

import codegen.wasm.emit_statements;
import codegen.wasm.emit_expressions;
import codegen.wasm.emit_calls;

/// Compute element size for a type in WASM target context.
/// Dynamic array elements are slice structs (sliceLayout.totalSize).
private uint wasmElementSize(Type elemType) {
    if (auto at = cast(ArrayType)elemType)
        if (!at.isStaticArray) return sliceLayout.totalSize;
    auto s = elemType.size();
    return s == 0 ? 4 : cast(uint)s;
}

class FuncContext {
    BinaryEmitter emitter;
    FuncInfo func;

    // Local variables (parameters + locals)
    ValType[] localTypes;
    uint paramCount;

    /// Discriminant for variable/parameter types in the unified var map.
    /// Used with `final switch` at multi-way dispatch points to ensure
    /// exhaustive handling — adding a new variant produces compile errors
    /// at every unhandled site.
    enum VarKind {
        scalar,
        struct_,
        class_,
        interface_,
        slice,
        staticArray,
        delegate_,
    }

    enum THIS_LOCAL_ID = uint.max - 1;  // Sentinel for 'this' parameter

    /// Address mode: how to emit code that loads/stores this variable
    enum AddrMode : ubyte {
        wasmLocal,       // scalar: local_get/set wasmLocalIdx
        shadowStack,     // aggregate local: FP + frameOffset
        paramPointer,    // aggregate param: local_get wasmLocalIdx (pointer)
    }

    /// Unified info for all local variables and parameters
    struct VarInfo {
        VarKind kind;
        AddrMode addrMode;

        uint wasmLocalIdx = uint.max;   // for wasmLocal and paramPointer
        uint frameOffset;               // for shadowStack
        uint itableLocalIdx = uint.max; // for interface params (second WASM local)

        Type type;
        StructDecl structDecl;
        ClassDecl classDecl;
        InterfaceDecl ifaceDecl;
        Type elementType;               // slice/static-array element type
        uint dataOffset, dataSize;      // slice inline data
        uint elementCount, elementSize; // static array
        FunctionDecl delegateLiftedFunc;  // for delegate_: the lifted lambda's FunctionDecl

        bool isStruct() const { return kind == VarKind.struct_; }
        bool isClass() const { return kind == VarKind.class_; }
        bool isInterface() const { return kind == VarKind.interface_; }
        bool isSlice() const { return kind == VarKind.slice; }
        bool isStaticArray() const { return kind == VarKind.staticArray; }
        bool isScalar() const { return kind == VarKind.scalar; }
        bool isDelegate() const { return kind == VarKind.delegate_; }
    }

    VarInfo[uint] varsByLocalId;    // uniqueLocalId → VarInfo (primary lookup)
    VarInfo[string] varsByName;     // name → VarInfo (fallback for "this", legacy)

    // Capture info for lifted lambdas (populated from FunctionLiteralExpression)
    struct CaptureInfo {
        string name;
        uint localId;      // lambda's local ID for this capture
        uint envOffset;    // byte offset in env struct
        Type type;
    }
    CaptureInfo[] captures;
    uint envParamIdx = uint.max;  // WASM local index of __env param

    /// Resolve a variable by localId (preferred) or name (fallback).
    /// Returns null if not found (e.g. globals, constants).
    VarInfo* resolveVar(uint localId, string name) {
        if (localId != uint.max) {
            if (auto p = localId in varsByLocalId)
                return p;
        }
        if (auto p = name in varsByName)
            return p;
        return null;
    }

    // ─── Opcode emission helpers ─────────────────────────────────────────

    void emitLocalGet(ref Appender!(ubyte[]) out_, uint idx) {
        out_ ~= Op.local_get;
        leb128u(out_, idx);
    }

    void emitLocalSet(ref Appender!(ubyte[]) out_, uint idx) {
        out_ ~= Op.local_set;
        leb128u(out_, idx);
    }

    void emitLocalTee(ref Appender!(ubyte[]) out_, uint idx) {
        out_ ~= Op.local_tee;
        leb128u(out_, idx);
    }

    void emitGlobalGet(ref Appender!(ubyte[]) out_, uint idx) {
        out_ ~= Op.global_get;
        leb128u(out_, idx);
    }

    void emitGlobalSet(ref Appender!(ubyte[]) out_, uint idx) {
        out_ ~= Op.global_set;
        leb128u(out_, idx);
    }

    void emitI32Const(ref Appender!(ubyte[]) out_, long value) {
        out_ ~= Op.i32_const;
        leb128s(out_, value);
    }

    void emitI64Const(ref Appender!(ubyte[]) out_, long value) {
        out_ ~= Op.i64_const;
        leb128s(out_, value);
    }

    void emitF64Const(ref Appender!(ubyte[]) out_, double value) {
        out_ ~= Op.f64_const;
        out_ ~= (cast(ubyte*)&value)[0 .. 8];
    }

    void emitF32Const(ref Appender!(ubyte[]) out_, float value) {
        out_ ~= Op.f32_const;
        out_ ~= (cast(ubyte*)&value)[0 .. 4];
    }

    void emitI32Load(ref Appender!(ubyte[]) out_, uint offset = 0) {
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte) 0x02;
        leb128u(out_, offset);
    }

    void emitI32Store(ref Appender!(ubyte[]) out_, uint offset = 0) {
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte) 0x02;
        leb128u(out_, offset);
    }

    void emitI64Load(ref Appender!(ubyte[]) out_, uint offset = 0) {
        out_ ~= Op.i64_load;
        out_ ~= cast(ubyte) 0x03;
        leb128u(out_, offset);
    }

    void emitI64Store(ref Appender!(ubyte[]) out_, uint offset = 0) {
        out_ ~= Op.i64_store;
        out_ ~= cast(ubyte) 0x03;
        leb128u(out_, offset);
    }

    void emitWasmCall(ref Appender!(ubyte[]) out_, uint funcIdx) {
        out_ ~= Op.call;
        leb128u(out_, funcIdx);
    }

    void emitBr(ref Appender!(ubyte[]) out_, uint depth) {
        out_ ~= Op.br;
        leb128u(out_, depth);
    }

    void emitBrIf(ref Appender!(ubyte[]) out_, uint depth) {
        out_ ~= Op.br_if;
        leb128u(out_, depth);
    }

    /// Emit FP + offset to compute a shadow-stack address.
    void emitFPOffset(ref Appender!(ubyte[]) out_, int offset) {
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, offset);
        out_ ~= Op.i32_add;
    }

    // ─── End opcode helpers ──────────────────────────────────────────────

    /// Emit the base address of a variable onto the WASM stack.
    /// For wasmLocal/paramPointer: emits local_get.
    /// For shadowStack: emits FP + frameOffset.
    void emitVarAddress(ref Appender!(ubyte[]) out_, const VarInfo* info) {
        final switch (info.addrMode) {
            case AddrMode.wasmLocal:
            case AddrMode.paramPointer:
                emitLocalGet(out_, info.wasmLocalIdx);
                break;
            case AddrMode.shadowStack:
                // FP + frameOffset
                emitFPOffset(out_, info.frameOffset);
                break;
        }
    }

    uint frameSize = 0;        // Total size of struct/slice locals on shadow stack
    uint savedSpLocal;         // Local index to store saved SP (for epilogue restore)
    uint fpLocal;              // Local index for frame pointer (stable, never changes)
    uint tempLocalA;           // Temp local for aggregate copy (dst addr)
    uint tempLocalB;           // Temp local for aggregate copy (src addr)
    uint tempLocalI64;         // Temp local for i64 values (e.g., i64-returning call exception check)
    uint tempLocalF64;         // Temp local for f64 values (e.g., f64-returning call exception check)
    uint tempLocalF32;         // Temp local for f32 values (e.g., f32-returning call exception check)
    
    // Block depth for br instructions
    uint blockDepth = 0;

    // Loop stack for break/continue
    struct LoopContext {
        uint breakBlockDepth;     // blockDepth of the outer block (break target)
        uint continueBlockDepth;  // blockDepth of the loop/inner block (continue target)
    }
    LoopContext[] loopStack;

    // Try/catch stack for exception handling
    struct TryContext {
        uint catchBlockDepth;  // blockDepth of the catch handler block
    }
    TryContext[] tryStack;

    // RAII tracking: struct locals that need destructor calls
    struct RAIIVarInfo {
        string name;           // Variable name
        uint frameOffset;      // Offset on shadow stack
        StructDecl structDecl; // Struct type (for destructor lookup)
        uint uniqueLocalId;    // Unique ID from type checker
    }
    RAIIVarInfo[uint] raiiVars;  // uniqueLocalId -> info
    
    // Method info: non-null structParent means we're in a method with hidden 'this'
    uint thisLocalIndex;  // Local index of hidden 'this' parameter (for methods)
    
    // Large return value info (structs, static arrays)
    bool hasLargeReturn = false;     // Function returns via hidden pointer
    uint resultPtrLocalIdx;          // WASM local index of hidden result pointer
    uint returnValueSize;            // Size of return value in bytes
    uint returnTempLocalIdx;         // Temp local for struct return copy (pre-allocated)

    // Arena parameter info
    bool hasArenaParam = false;      // Function has hidden __arena parameter
    uint arenaLocalIdx;              // WASM local index of hidden __arena pointer
    
    // Call stack frame info (milestone 144)
    bool enableStackTrace = false;
    uint frameNameOffset;
    uint frameNameLen;
    uint frameFileOffset;
    uint frameFileLen;
    uint frameLine;
    uint frameColumn;
    
    bool isObjCMethod;  // true when this function is an extern(Objective-C) class method
    uint objcCmdLocalIdx;  // WASM local index of hidden _cmd parameter (i64)

    this(FuncInfo f, BinaryEmitter e) {
        import codegen.param_layout : ParamRole;

        this.func = f;
        this.emitter = e;

        // --- Special path for extern(Objective-C) class methods ---
        // These have a different calling convention: (self:i64, _cmd:i64, ...user_params)
        // No ParamLayout is used — locals are set up directly from the WASM signature.
        if (f.classParent !is null && f.classParent.isObjC) {
            initObjCClassMethod(f, e);
            return;
        }

        // --- Register all parameters from canonical ParamLayout ---
        foreach (ref entry; f.paramLayout.entries) {
            uint wasmIdx = cast(uint)localTypes.length;

            final switch (entry.role) {
                case ParamRole.this_:
                    localTypes ~= ValType.i32;
                    thisLocalIndex = wasmIdx;

                    VarInfo vi;
                    if (f.structParent !is null) {
                        vi.kind = VarKind.struct_;
                        vi.structDecl = f.structParent;
                    } else if (f.classParent !is null) {
                        vi.kind = VarKind.class_;
                        vi.classDecl = f.classParent;
                    }
                    vi.addrMode = AddrMode.paramPointer;
                    vi.wasmLocalIdx = wasmIdx;
                    varsByLocalId[THIS_LOCAL_ID] = vi;
                    varsByName["this"] = vi;
                    break;

                case ParamRole.resultPtr:
                    resultPtrLocalIdx = wasmIdx;
                    localTypes ~= ValType.i32;
                    hasLargeReturn = true;

                    // Resolve return type and calculate return value size
                    if (auto ut = cast(UserType)f.decl.returnType)
                        ut.ensureResolved(e.symbolTable);

                    if (auto arrType = cast(ArrayType)f.decl.returnType) {
                        if (arrType.arraySize !is null) {
                            uint elemCount = evaluateStaticArraySize(arrType.arraySize);
                            size_t elemSize = arrType.elementType.size();
                            if (elemSize == 0) elemSize = 4;
                            returnValueSize = elemCount * cast(uint)elemSize;
                        } else {
                            returnValueSize = sliceLayout.totalSize;
                        }
                    } else if (auto sd = f.decl.returnType.asStruct()) {
                        returnValueSize = cast(uint)sd.structSize;
                    } else {
                        returnValueSize = cast(uint)f.decl.returnType.size();
                    }
                    break;

                case ParamRole.arena:
                    arenaLocalIdx = wasmIdx;
                    localTypes ~= ValType.i32;
                    hasArenaParam = true;
                    break;

                case ParamRole.user:
                    auto p = f.decl.parameters[entry.userIndex];

                    if (entry.isInterfaceParam) {
                        // Interface: fat pointer = 2 i32 locals (obj_ptr, itable_ptr)
                        localTypes ~= ValType.i32;
                        localTypes ~= ValType.i32;

                        VarInfo uvi;
                        uvi.kind = VarKind.interface_;
                        uvi.addrMode = AddrMode.paramPointer;
                        uvi.wasmLocalIdx = wasmIdx;
                        uvi.itableLocalIdx = wasmIdx + 1;
                        uvi.type = p.type;
                        if (auto userType = cast(UserType)p.type)
                            uvi.ifaceDecl = userType.asInterface();
                        if (entry.uniqueLocalId != uint.max)
                            varsByLocalId[entry.uniqueLocalId] = uvi;
                        varsByName[entry.name] = uvi;
                    } else {
                        localTypes ~= entry.wasmType;

                        VarInfo uvi;
                        uvi.wasmLocalIdx = wasmIdx;
                        uvi.type = p.type;

                        if (auto structDecl = p.type.asStruct()) {
                            uvi.kind = VarKind.struct_;
                            uvi.addrMode = AddrMode.paramPointer;
                            uvi.structDecl = structDecl;
                        } else if (auto classDecl = p.type.asClass()) {
                            uvi.kind = VarKind.class_;
                            uvi.addrMode = AddrMode.paramPointer;
                            uvi.classDecl = classDecl;
                        } else if (auto arrayType = cast(ArrayType)p.type) {
                            if (arrayType.arraySize !is null) {
                                uvi.kind = VarKind.staticArray;
                                uvi.addrMode = AddrMode.paramPointer;
                                uvi.elementType = arrayType.elementType;
                                uvi.elementCount = evaluateStaticArraySize(arrayType.arraySize);
                                uvi.elementSize = wasmElementSize(arrayType.elementType);
                            } else {
                                uvi.kind = VarKind.slice;
                                uvi.addrMode = AddrMode.paramPointer;
                                uvi.elementType = arrayType.elementType;
                                uvi.elementSize = wasmElementSize(arrayType.elementType);
                            }
                        } else if (cast(FunctionType)p.type) {
                            uvi.kind = VarKind.delegate_;
                            uvi.addrMode = AddrMode.paramPointer;
                        } else {
                            uvi.kind = VarKind.scalar;
                            uvi.addrMode = AddrMode.wasmLocal;
                        }

                        if (entry.uniqueLocalId != uint.max)
                            varsByLocalId[entry.uniqueLocalId] = uvi;
                        varsByName[entry.name] = uvi;
                    }
                    break;
            }
        }
        paramCount = f.paramLayout.wasmLocalCount;

        // Pre-allocate temp local for struct return copy (must be after paramCount)
        if (hasLargeReturn) {
            returnTempLocalIdx = cast(uint)localTypes.length;
            localTypes ~= ValType.i32;
        }

        // Register call stack frame info if stack trace is enabled
        if (e.enableStackTrace) {
            enableStackTrace = true;
            string fileName = f.decl.location.filename;
            if (fileName.length == 0) fileName = "<unknown>";

            auto frameInfo = e.registerCallStackFrame(
                f.name,
                fileName,
                f.decl.location.line,
                f.decl.location.column
            );
            frameNameOffset = frameInfo.nameOffset;
            frameNameLen = frameInfo.nameLen;
            frameFileOffset = frameInfo.fileOffset;
            frameFileLen = frameInfo.fileLen;
            frameLine = frameInfo.line;
            frameColumn = frameInfo.column;
        }

        // Populate capture info for lifted lambdas
        if (f.lambdaExpr !is null && !f.lambdaExpr.isNonCapturing) {
            envParamIdx = 0;  // __env is always the first WASM param (local index 0)
            foreach (i, capName; f.lambdaExpr.capturedNames) {
                CaptureInfo ci;
                ci.name = capName;
                ci.envOffset = f.lambdaExpr.capturedOffsets[i];
                ci.type = f.lambdaExpr.capturedTypes[i];
                ci.localId = uint.max;  // matched by name
                captures ~= ci;
            }
        }
    }
    
    /**
     * Initialize locals for an extern(Objective-C) class method.
     * Calling convention: (self:i64, _cmd:i64, ...user_params) → return_type
     * self and _cmd are i64 WASM locals (native ObjC pointers).
     */
    private void initObjCClassMethod(FuncInfo f, BinaryEmitter e) {
        isObjCMethod = true;

        // Local 0: self (i64) — registered as "this" with special ObjC handling
        uint selfIdx = cast(uint)localTypes.length;
        localTypes ~= ValType.i64;
        thisLocalIndex = selfIdx;

        VarInfo selfVi;
        selfVi.kind = VarKind.class_;
        selfVi.classDecl = f.classParent;
        selfVi.addrMode = AddrMode.wasmLocal;  // i64 scalar, not a WASM memory pointer
        selfVi.wasmLocalIdx = selfIdx;
        varsByLocalId[THIS_LOCAL_ID] = selfVi;
        varsByName["this"] = selfVi;

        // Local 1: _cmd (i64) — ObjC selector, not directly used by D code
        objcCmdLocalIdx = cast(uint)localTypes.length;
        localTypes ~= ValType.i64;

        // Locals 2+: user parameters
        foreach (i, p; f.decl.parameters) {
            uint wasmIdx = cast(uint)localTypes.length;
            auto resolved = p.type.resolve();

            // Resolve UserType declarations
            if (auto ut = cast(UserType)resolved) {
                if (!ut.declaration) ut.ensureResolved(e.symbolTable);
            }

            // ObjC interface/class params are i64
            if (auto ut = cast(UserType)resolved) {
                if (auto ifaceDecl = cast(InterfaceDecl)ut.declaration) {
                    if (ifaceDecl.isObjC) {
                        localTypes ~= ValType.i64;
                        VarInfo uvi;
                        uvi.kind = VarKind.interface_;
                        uvi.addrMode = AddrMode.wasmLocal;
                        uvi.wasmLocalIdx = wasmIdx;
                        uvi.type = p.type;
                        uvi.ifaceDecl = ifaceDecl;
                        if (p.uniqueLocalId != uint.max) varsByLocalId[p.uniqueLocalId] = uvi;
                        varsByName[p.name] = uvi;
                        continue;
                    }
                }
            }

            // Struct params: flattened HFA
            if (auto structDecl = resolved.asStruct()) {
                // First local is the start of the flattened fields
                foreach (field; structDecl.fields) {
                    localTypes ~= e.dTypeToValType(field.type);
                }
                VarInfo uvi;
                uvi.kind = VarKind.struct_;
                uvi.addrMode = AddrMode.wasmLocal;
                uvi.wasmLocalIdx = wasmIdx;
                uvi.structDecl = structDecl;
                uvi.type = p.type;
                if (p.uniqueLocalId != uint.max) varsByLocalId[p.uniqueLocalId] = uvi;
                varsByName[p.name] = uvi;
                continue;
            }

            // Regular scalar params
            localTypes ~= e.dTypeToValType(p.type);
            VarInfo uvi;
            uvi.kind = VarKind.scalar;
            uvi.addrMode = AddrMode.wasmLocal;
            uvi.wasmLocalIdx = wasmIdx;
            uvi.type = p.type;
            if (p.uniqueLocalId != uint.max) varsByLocalId[p.uniqueLocalId] = uvi;
            varsByName[p.name] = uvi;
        }

        paramCount = cast(uint)localTypes.length;
    }

    /**
     * Collect local variable declarations from statements
     */
    void collectLocals(Statement stmt) {
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                collectLocals(s);
            }
        } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
            // Check if it's a user-defined type (struct/class/interface)
            if (auto userType = cast(UserType)varDecl.type) {
                userType.ensureResolved(emitter.symbolTable);

                if (auto structDecl = userType.asStruct()) {
                    // Struct local - allocate on shadow stack
                    // Align frameSize to struct's alignment (assume 4 for now)
                    frameSize = (frameSize + 3) & ~3;

                    VarInfo vi;
                    vi.kind = VarKind.struct_;
                    vi.addrMode = AddrMode.shadowStack;
                    vi.frameOffset = frameSize;
                    vi.type = varDecl.type;
                    vi.structDecl = structDecl;
                    if (varDecl.uniqueLocalId != uint.max)
                        varsByLocalId[varDecl.uniqueLocalId] = vi;
                    varsByName[varDecl.name] = vi;

                    // Track for RAII if struct has destructor
                    if (structDecl.hasDestructor()) {
                        RAIIVarInfo raiiInfo;
                        raiiInfo.name = varDecl.name;
                        raiiInfo.frameOffset = frameSize;
                        raiiInfo.structDecl = structDecl;
                        raiiInfo.uniqueLocalId = varDecl.uniqueLocalId;
                        raiiVars[varDecl.uniqueLocalId] = raiiInfo;
                    }

                    frameSize += structDecl.structSize;
                    return;
                }

                // Class local
                if (auto classDecl = userType.asClass()) {
                    if (classDecl.isObjC && varDecl.initializer !is null) {
                        // ObjC class: i64 WASM local (opaque native pointer, like ObjC interface)
                        VarInfo vi;
                        vi.kind = VarKind.class_;
                        vi.addrMode = AddrMode.wasmLocal;
                        vi.wasmLocalIdx = cast(uint)localTypes.length;
                        localTypes ~= ValType.i64;
                        vi.type = varDecl.type;
                        vi.classDecl = classDecl;
                        if (varDecl.uniqueLocalId != uint.max)
                            varsByLocalId[varDecl.uniqueLocalId] = vi;
                        varsByName[varDecl.name] = vi;
                        return;
                    }
                    if (varDecl.initializer !is null) {
                        // D class reference — stored as i32 WASM local (D reference semantics)
                        VarInfo vi;
                        vi.kind = VarKind.class_;
                        vi.addrMode = AddrMode.wasmLocal;
                        vi.wasmLocalIdx = cast(uint)localTypes.length;
                        localTypes ~= ValType.i32;
                        vi.type = varDecl.type;
                        vi.classDecl = classDecl;
                        if (varDecl.uniqueLocalId != uint.max)
                            varsByLocalId[varDecl.uniqueLocalId] = vi;
                        varsByName[varDecl.name] = vi;
                        return;
                    }

                    // Stack-allocated class (no initializer) — existing behavior
                    frameSize = (frameSize + cast(uint)classDecl.classAlign - 1) & ~(cast(uint)classDecl.classAlign - 1);

                    VarInfo vi;
                    vi.kind = VarKind.class_;
                    vi.addrMode = AddrMode.shadowStack;
                    vi.frameOffset = frameSize;
                    vi.type = varDecl.type;
                    vi.classDecl = classDecl;
                    if (varDecl.uniqueLocalId != uint.max)
                        varsByLocalId[varDecl.uniqueLocalId] = vi;
                    varsByName[varDecl.name] = vi;

                    frameSize += cast(uint)classDecl.classSize;
                    return;
                }

                // Interface local
                if (auto ifaceDecl = userType.asInterface()) {
                    if (ifaceDecl.isObjC) {
                        // ObjC interface: simple i64 WASM local (opaque native pointer)
                        VarInfo vi;
                        vi.kind = VarKind.interface_;
                        vi.addrMode = AddrMode.wasmLocal;
                        vi.wasmLocalIdx = cast(uint)localTypes.length;
                        localTypes ~= ValType.i64;
                        vi.type = varDecl.type;
                        vi.ifaceDecl = ifaceDecl;
                        if (varDecl.uniqueLocalId != uint.max)
                            varsByLocalId[varDecl.uniqueLocalId] = vi;
                        varsByName[varDecl.name] = vi;
                        return;
                    }

                    // Regular D interface: fat pointer on shadow stack (8 bytes)
                    frameSize = (frameSize + 3) & ~3;  // Align to 4 bytes

                    VarInfo vi;
                    vi.kind = VarKind.interface_;
                    vi.addrMode = AddrMode.shadowStack;
                    vi.frameOffset = frameSize;
                    vi.type = varDecl.type;
                    vi.ifaceDecl = ifaceDecl;
                    if (varDecl.uniqueLocalId != uint.max)
                        varsByLocalId[varDecl.uniqueLocalId] = vi;
                    varsByName[varDecl.name] = vi;

                    frameSize += 8;  // Fat pointer: obj_ptr + itable_ptr
                    return;
                }
            }
            
            // Check if it's a slice/array type
            if (auto arrayType = cast(ArrayType)varDecl.type) {
                // Static array (int[4]) vs dynamic array/slice (int[])
                if (arrayType.arraySize !is null) {
                    // Static array - allocate contiguous data on shadow stack
                    frameSize = (frameSize + 3) & ~3;  // Align to 4 bytes
                    
                    // Evaluate array size (must be compile-time constant)
                    uint elemCount = evaluateStaticArraySize(arrayType.arraySize);
                    uint elemSize = wasmElementSize(arrayType.elementType);

                    VarInfo vi;
                    vi.kind = VarKind.staticArray;
                    vi.addrMode = AddrMode.shadowStack;
                    vi.frameOffset = frameSize;
                    vi.type = varDecl.type;
                    vi.elementType = arrayType.elementType;
                    vi.elementCount = elemCount;
                    vi.elementSize = elemSize;
                    if (varDecl.uniqueLocalId != uint.max)
                        varsByLocalId[varDecl.uniqueLocalId] = vi;
                    varsByName[varDecl.name] = vi;

                    frameSize += elemCount * elemSize;
                    return;
                }
                
                // Dynamic array/slice - allocate sliceLayout.totalSize bytes for slice struct (ptr, length, capacity)
                frameSize = (frameSize + 3) & ~3;  // Align to 4 bytes
                
                // Enable array support for __alloc, etc.
                emitter.needsArraySupport = true;
                
                VarInfo vi;
                vi.kind = VarKind.slice;
                vi.addrMode = AddrMode.shadowStack;
                vi.frameOffset = frameSize;
                vi.type = varDecl.type;
                vi.elementType = arrayType.elementType;
                vi.elementSize = wasmElementSize(arrayType.elementType);

                // Slice struct is sliceLayout.totalSize bytes (ptr: i32, length: i32, capacity: i32)
                frameSize += sliceLayout.totalSize;

                // If initialized with array literal, also allocate space for data
                if (auto arrayLit = cast(ArrayLiteralExpression)varDecl.initializer) {
                    frameSize = (frameSize + 3) & ~3;  // Align data
                    vi.dataOffset = frameSize;

                    // Calculate data size based on element type and count
                    size_t elemSize = arrayType.elementType.size();
                    if (elemSize == 0) elemSize = 4;  // Default to 4 for i32
                    vi.dataSize = cast(uint)(elemSize * arrayLit.elements.length);

                    frameSize += vi.dataSize;
                }

                if (varDecl.uniqueLocalId != uint.max)
                    varsByLocalId[varDecl.uniqueLocalId] = vi;
                varsByName[varDecl.name] = vi;

                return;
            }

            // Delegate/function type local — 8 bytes on shadow stack
            if (auto funcType = cast(FunctionType)varDecl.type) {
                frameSize = (frameSize + 3) & ~3;  // Align to 4 bytes

                VarInfo vi;
                vi.kind = VarKind.delegate_;
                vi.addrMode = AddrMode.shadowStack;
                vi.frameOffset = frameSize;
                vi.type = varDecl.type;

                // Store the lifted function reference for call_indirect type lookup
                if (auto funcLit = cast(FunctionLiteralExpression)varDecl.initializer) {
                    vi.delegateLiftedFunc = funcLit.liftedFunction;
                }

                if (varDecl.uniqueLocalId != uint.max)
                    varsByLocalId[varDecl.uniqueLocalId] = vi;
                varsByName[varDecl.name] = vi;

                frameSize += 8;  // {tableIndex: i32, envPtr: i32}

                // Allocate env struct on shadow stack for capturing lambdas
                if (auto funcLit = cast(FunctionLiteralExpression)varDecl.initializer) {
                    if (!funcLit.isNonCapturing && funcLit.envSize > 0) {
                        frameSize = (frameSize + 3) & ~3;
                        funcLit.envFrameOffset = frameSize;
                        frameSize += funcLit.envSize;
                    }
                }

                return;
            }

            // Stack-promoted new: reserve shadow stack space for the allocation,
            // but keep the variable as a scalar i32 (pointer) in a WASM local
            if (auto newExpr = cast(NewExpression)varDecl.initializer) {
                if (newExpr.stackPromoted && newExpr.resolvedStruct !is null) {
                    auto sd = newExpr.resolvedStruct;
                    frameSize = (frameSize + 3) & ~3;
                    newExpr.stackFrameOffset = frameSize;
                    frameSize += sd.structSize;

                    // The variable itself is a scalar pointer (i32 WASM local)
                    uint wasmIdx = cast(uint)localTypes.length;
                    localTypes ~= ValType.i32;

                    VarInfo vi;
                    vi.kind = VarKind.scalar;
                    vi.addrMode = AddrMode.wasmLocal;
                    vi.wasmLocalIdx = wasmIdx;
                    vi.type = varDecl.type;
                    if (varDecl.uniqueLocalId != uint.max)
                        varsByLocalId[varDecl.uniqueLocalId] = vi;
                    varsByName[varDecl.name] = vi;
                    return;
                }
            }

            // Regular local - add to WASM locals (or shadow stack if captured)
            if (varDecl.isCaptured) {
                // Captured scalar: promote to shadow stack for addressability
                frameSize = (frameSize + 3) & ~3;
                VarInfo vi;
                vi.kind = VarKind.scalar;
                vi.addrMode = AddrMode.shadowStack;
                vi.frameOffset = frameSize;
                vi.type = varDecl.type;
                if (varDecl.uniqueLocalId != uint.max)
                    varsByLocalId[varDecl.uniqueLocalId] = vi;
                varsByName[varDecl.name] = vi;
                frameSize += 4;
                return;
            }

            auto vt = emitter.dTypeToValType(varDecl.type);
            uint wasmIdx = cast(uint)localTypes.length;
            localTypes ~= vt;

            VarInfo vi;
            vi.kind = VarKind.scalar;
            vi.addrMode = AddrMode.wasmLocal;
            vi.wasmLocalIdx = wasmIdx;
            vi.type = varDecl.type;
            if (varDecl.uniqueLocalId != uint.max)
                varsByLocalId[varDecl.uniqueLocalId] = vi;
            varsByName[varDecl.name] = vi;
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            collectLocals(ifStmt.thenStatement);
            if (ifStmt.elseStatement) {
                collectLocals(ifStmt.elseStatement);
            }
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            collectLocals(whileStmt.body_);
        } else if (auto forStmt = cast(ForStatement)stmt) {
            if (forStmt.init) collectLocals(forStmt.init);
            collectLocals(forStmt.body_);
        } else if (auto mixinStmt = cast(MixinStatement)stmt) {
            if (mixinStmt.isExpanded) {
                foreach (s; mixinStmt.expandedStatements) {
                    collectLocals(s);
                }
            }
        } else if (auto tryStmt = cast(TryStatement)stmt) {
            collectLocals(tryStmt.tryBody);
            foreach (c; tryStmt.catches) {
                // Allocate WASM local for catch parameter
                if (c.paramName !is null && c.paramName.length > 0) {
                    uint wasmIdx = cast(uint)localTypes.length;
                    localTypes ~= ValType.i32;
                    VarInfo vi;
                    vi.kind = VarKind.scalar;
                    vi.addrMode = AddrMode.wasmLocal;
                    vi.wasmLocalIdx = wasmIdx;
                    vi.type = c.exceptionType;
                    varsByName[c.paramName] = vi;
                }
                if (c.body_)
                    collectLocals(c.body_);
            }
            if (tryStmt.finallyBody)
                collectLocals(tryStmt.finallyBody);
        } else if (cast(ReturnStatement)stmt || cast(ExpressionStatement)stmt
                   || cast(BreakStatement)stmt || cast(ContinueStatement)stmt
                   || cast(StructDeclarationStatement)stmt) {
            // No local declarations to collect
        } else {
            assert(0, "collectLocals: unhandled statement type: " ~ typeid(stmt).name);
        }
    }
    
    /**
     * Evaluate static array size expression (must be compile-time constant)
     */
    uint evaluateStaticArraySize(Expression sizeExpr) {
        if (auto lit = cast(LiteralExpression)sizeExpr) {
            if (lit.value.type == typeid(long)) {
                return cast(uint)lit.value.get!long();
            } else if (lit.value.type == typeid(int)) {
                return cast(uint)lit.value.get!int();
            }
        }
        // TODO: Handle more complex constant expressions
        throw new EmitError("Static array size must be a compile-time constant integer", sizeExpr.location);
    }
    
    /**
     * Finalize locals after collection - add saved SP and FP locals if needed
     */
    void finalizeLocals() {
        // Always allocate temp locals — they're used for aggregate copy, slice field
        // append, struct return copy, etc. Previously only allocated when frameSize > 0,
        // which caused tempLocalA to default to 0 (aliasing the 'this' parameter in methods).
        tempLocalA = cast(uint)localTypes.length;
        localTypes ~= ValType.i32;
        tempLocalB = cast(uint)localTypes.length;
        localTypes ~= ValType.i32;
        tempLocalI64 = cast(uint)localTypes.length;
        localTypes ~= ValType.i64;
        tempLocalF64 = cast(uint)localTypes.length;
        localTypes ~= ValType.f64;
        tempLocalF32 = cast(uint)localTypes.length;
        localTypes ~= ValType.f32;

        if (frameSize > 0) {
            // Need locals for saved SP (epilogue restore) and FP (stable frame access)
            savedSpLocal = cast(uint)localTypes.length;
            localTypes ~= ValType.i32;
            fpLocal = cast(uint)localTypes.length;
            localTypes ~= ValType.i32;
        }
    }
    
    /**
     * Emit shadow stack prologue (if function has struct locals)
     * 
     * savedSp = $sp
     * $sp = $sp - frameSize
     * FP = $sp   (frame pointer - stable reference for locals)
     */
    void emitPrologue(ref Appender!(ubyte[]) out_) {
        // First, emit call stack push if enabled
        if (enableStackTrace) {
            emitCallStackPush(out_);
        }
        
        if (frameSize == 0) return;
        
        // savedSp = global.get $sp
        emitGlobalGet(out_, emitter.spGlobal);
        emitLocalSet(out_, savedSpLocal);
        
        // $sp = $sp - frameSize
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, frameSize);
        out_ ~= Op.i32_sub;
        emitGlobalSet(out_, emitter.spGlobal);
        
        // FP = $sp (frame pointer for stable local access)
        emitGlobalGet(out_, emitter.spGlobal);
        emitLocalSet(out_, fpLocal);
    }
    
    /**
     * Emit shadow stack epilogue (restores SP before implicit return)
     * 
     * $sp = savedSp
     */
    void emitEpilogue(ref Appender!(ubyte[]) out_) {
        // Pop call stack frame on normal return only — preserve during exception propagation
        // so the host can read the call chain for error reporting
        if (enableStackTrace) {
            emitGlobalGet(out_, emitter.exceptionPendingGlobal);
            out_ ~= Op.i32_eqz;
            out_ ~= Op.if_;
            out_ ~= cast(ubyte)BlockType.void_;
            blockDepth++;
            emitCallStackPop(out_);
            blockDepth--;
            out_ ~= Op.end;
        }

        if (frameSize == 0) return;

        // $sp = savedSp
        emitLocalGet(out_, savedSpLocal);
        emitGlobalSet(out_, emitter.spGlobal);
    }

    /// Push the current arena pointer onto the WASM stack.
    /// Uses the function's hidden arena parameter if available,
    /// otherwise falls back to the global root arena.
    void emitArenaPointer(ref Appender!(ubyte[]) out_) {
        if (hasArenaParam) {
            emitLocalGet(out_, arenaLocalIdx);
        } else {
            emitGlobalGet(out_, emitter.arenaBaseGlobal);
        }
    }

    /// Emit __arena_new (save watermark) or __arena_drop (restore watermark).
    /// No-op if this function doesn't have an arena parameter.
    /// Also skipped for functions returning slices — their arena allocations
    /// must survive into the caller's scope (the caller's drop handles cleanup).
    void emitArenaScopeCall(ref Appender!(ubyte[]) out_, bool isNew) {
        if (!hasArenaParam) return;
        if (returnsArenaData) return;
        emitArenaPointer(out_);
        emitWasmCall(out_, isNew ? emitter.arenaNewFuncIndex : emitter.arenaDropFuncIndex);
    }

    /// Returns true if this function's return type contains pointers to arena memory
    /// (dynamic slices). Static arrays are on the shadow stack, so they're safe to drop.
    private bool returnsArenaData() {
        if (auto arrType = cast(ArrayType)func.decl.returnType)
            return arrType.arraySize is null;  // Dynamic slice, not static array
        return false;
    }

    /**
     * Emit call stack push - called at function entry.
     * 
     * Depth is stored in memory at offset 0 (not a global) so it can be
     * read by the host after a trap.
     * 
     * if (mem[0] < 64) {
     *     frameAddr = 8 + mem[0] * 24
     *     store nameOffset, nameLen, fileOffset, fileLen, line, column
     *     mem[0]++
     * }
     */
    void emitCallStackPush(ref Appender!(ubyte[]) out_) {
        import codegen.wasm.types : CALL_STACK_DEPTH_OFFSET, CALL_STACK_FRAMES_OFFSET, 
                                    CALL_STACK_FRAME_SIZE, CALL_STACK_MAX_FRAMES;
        
        // Load current depth from memory
        emitI32Const(out_, CALL_STACK_DEPTH_OFFSET);
        emitI32Load(out_, 0x00);

        // Check if depth < 64
        emitI32Const(out_, CALL_STACK_MAX_FRAMES);
        out_ ~= Op.i32_lt_u;

        // if (depth < 64) {
        out_ ~= Op.if_;
        out_ ~= BlockType.void_;  // No result

        // Calculate frame address: 8 + depth * 24
        emitI32Const(out_, CALL_STACK_FRAMES_OFFSET);
        emitI32Const(out_, CALL_STACK_DEPTH_OFFSET);
        emitI32Load(out_, 0x00);
        emitI32Const(out_, CALL_STACK_FRAME_SIZE);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;
        // Stack: [frameAddr]

        // Store nameOffset at frameAddr + 0
        emitI32Const(out_, frameNameOffset);
        emitI32Store(out_, 0x00);

        // Recalculate frameAddr for next store (depth still same)
        emitI32Const(out_, CALL_STACK_FRAMES_OFFSET);
        emitI32Const(out_, CALL_STACK_DEPTH_OFFSET);
        emitI32Load(out_, 0x00);
        emitI32Const(out_, CALL_STACK_FRAME_SIZE);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;

        // Store nameLen at frameAddr + 4
        emitI32Const(out_, frameNameLen);
        emitI32Store(out_, 0x04);

        // Recalculate frameAddr
        emitI32Const(out_, CALL_STACK_FRAMES_OFFSET);
        emitI32Const(out_, CALL_STACK_DEPTH_OFFSET);
        emitI32Load(out_, 0x00);
        emitI32Const(out_, CALL_STACK_FRAME_SIZE);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;

        // Store fileOffset at frameAddr + 8
        emitI32Const(out_, frameFileOffset);
        emitI32Store(out_, 0x08);

        // Recalculate frameAddr
        emitI32Const(out_, CALL_STACK_FRAMES_OFFSET);
        emitI32Const(out_, CALL_STACK_DEPTH_OFFSET);
        emitI32Load(out_, 0x00);
        emitI32Const(out_, CALL_STACK_FRAME_SIZE);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;

        // Store fileLen at frameAddr + 12
        emitI32Const(out_, frameFileLen);
        emitI32Store(out_, 0x0C);

        // Recalculate frameAddr
        emitI32Const(out_, CALL_STACK_FRAMES_OFFSET);
        emitI32Const(out_, CALL_STACK_DEPTH_OFFSET);
        emitI32Load(out_, 0x00);
        emitI32Const(out_, CALL_STACK_FRAME_SIZE);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;

        // Store line at frameAddr + 16
        emitI32Const(out_, frameLine);
        emitI32Store(out_, 0x10);

        // Recalculate frameAddr
        emitI32Const(out_, CALL_STACK_FRAMES_OFFSET);
        emitI32Const(out_, CALL_STACK_DEPTH_OFFSET);
        emitI32Load(out_, 0x00);
        emitI32Const(out_, CALL_STACK_FRAME_SIZE);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;

        // Store column at frameAddr + 20
        emitI32Const(out_, frameColumn);
        emitI32Store(out_, 0x14);

        // Increment depth: mem[0] = mem[0] + 1
        emitI32Const(out_, CALL_STACK_DEPTH_OFFSET);
        emitI32Const(out_, CALL_STACK_DEPTH_OFFSET);
        emitI32Load(out_, 0x00);
        emitI32Const(out_, 1);
        out_ ~= Op.i32_add;
        emitI32Store(out_, 0x00);

        // end if
        out_ ~= Op.end;
    }
    
    /**
     * Emit call stack pop - called at function exit.
     * 
     * mem[0]--
     */
    void emitCallStackPop(ref Appender!(ubyte[]) out_) {
        import codegen.wasm.types : CALL_STACK_DEPTH_OFFSET;
        
        // Decrement depth: mem[0] = mem[0] - 1
        emitI32Const(out_, CALL_STACK_DEPTH_OFFSET);
        emitI32Const(out_, CALL_STACK_DEPTH_OFFSET);
        emitI32Load(out_, 0x00);
        emitI32Const(out_, 1);
        out_ ~= Op.i32_sub;
        emitI32Store(out_, 0x00);
    }
    
    /**
     * Emit checked division or modulo: if divisor is zero, write an exception
     * slot and propagate as a regular exception (no unreachable trap).
     *
     * Stack on entry: [..., dividend, divisor]
     * Stack on exit:  [..., quotient_or_remainder]
     */
    void emitCheckedDivOrMod(ref Appender!(ubyte[]) out_, Op divOp, SourceLocation loc) {
        import codegen.error_kind : ErrorKind;

        // This function uses i32 locals (tempLocalB) and i32_eqz — only valid for i32 operands
        assert(divOp == Op.i32_div_s || divOp == Op.i32_rem_s || divOp == Op.i32_rem_u,
            "emitCheckedDivOrMod: only i32 div/mod ops supported, got f64/i64 — caller must handle float division directly");

        // Save divisor, test for zero
        //   Stack: [..., dividend, divisor]
        emitLocalTee(out_, tempLocalB);
        //   Stack: [..., dividend, divisor]  (divisor also in tempLocalB)
        out_ ~= Op.i32_eqz;
        //   Stack: [..., dividend, is_zero]

        out_ ~= Op.if_;
        out_ ~= BlockType.void_;
        blockDepth++;

        // Note: the dividend is on the OUTER stack, not inside this void block.
        // We must NOT drop it here — void blocks start with an empty virtual stack.
        // The dividend remains on the outer stack and is consumed by divOp after `end`.

        // Determine error kind: DivByZero for div_s, ModByZero for rem_s
        auto kind = (divOp == Op.i32_rem_s || divOp == Op.i32_rem_u)
            ? ErrorKind.ModByZero : ErrorKind.DivByZero;

        // Write exception slot and set pending flag (value=0 for runtime errors)
        emitExceptionSlotWrite(out_, kind, loc);

        if (tryStack.length > 0) {
            // Inside a try block: branch to catch handler
            emitBr(out_, blockDepth - tryStack[$ - 1].catchBlockDepth);
        } else {
            // Not in a try block: propagate by returning.
            // Don't call emitCallStackOverwrite here — the error originates in THIS
            // function, so the call stack frame should keep the function-definition
            // location. The precise error location is already in the exception slot.
            emitDummyReturnValue(out_);
            emitEpilogue(out_);
            out_ ~= Op.return_;
        }

        blockDepth--;
        out_ ~= Op.end;

        // Restore divisor and perform the operation
        //   Stack: [..., dividend]
        emitLocalGet(out_, tempLocalB);
        //   Stack: [..., dividend, divisor]
        out_ ~= divOp;
    }

    /**
     * Emit destructor calls for variables going out of scope.
     * Called at the end of compound statements and before return.
     * Variables are destructed in reverse declaration order.
     */
    void emitScopeDestructors(ref Appender!(ubyte[]) out_, uint[] varIds) {
        // Destruct in reverse order (last declared first)
        foreach_reverse (varId; varIds) {
            if (auto raiiInfo = varId in raiiVars) {
                emitDestructorCall(out_, *raiiInfo);
            }
        }
    }
    
    /**
     * Emit a destructor call for a single struct variable.
     * The destructor is called with a pointer to the struct (this).
     */
    void emitDestructorCall(ref Appender!(ubyte[]) out_, RAIIVarInfo info) {
        // Get the destructor function
        auto dtor = info.structDecl.destructor;
        if (dtor is null) return;
        
        // Push the address of the struct (this pointer)
        // FP + frameOffset
        emitFPOffset(out_, info.frameOffset);
        
        // Call the destructor using its mangled name
        string dtorName = dtor.mangledName ? dtor.mangledName : info.structDecl.name ~ "_~this";
        if (auto funcIdx = dtorName in emitter.funcIndex) {
            emitWasmCall(out_, cast(uint)emitter.imports.length + *funcIdx);
        } else {
            // Destructor not registered - this shouldn't happen
            // For now, just drop the this pointer
            out_ ~= Op.drop;
        }
    }
    
    /**
     * Emit destructor calls for all scopes being unwound (on return).
     * unwindChain[0] is innermost scope, [n-1] is function scope.
     */
    void emitUnwindDestructors(ref Appender!(ubyte[]) out_, uint[][] unwindChain) {
        foreach (scopeVars; unwindChain) {
            emitScopeDestructors(out_, scopeVars);
        }
    }
    
    /**
     * Emit local declarations (non-parameter locals)
     */
    void emitLocalDecls(ref Appender!(ubyte[]) out_) {
        auto nonParamLocals = localTypes[paramCount .. $];
        
        if (nonParamLocals.length == 0) {
            leb128u(out_, 0);  // 0 local groups
            return;
        }
        
        // Group consecutive same-type locals
        struct LocalGroup { uint count; ValType type; }
        LocalGroup[] groups;
        
        ValType currentType = nonParamLocals[0];
        uint currentCount = 1;
        
        foreach (t; nonParamLocals[1 .. $]) {
            if (t == currentType) {
                currentCount++;
            } else {
                groups ~= LocalGroup(currentCount, currentType);
                currentType = t;
                currentCount = 1;
            }
        }
        groups ~= LocalGroup(currentCount, currentType);
        
        // Emit groups
        leb128u(out_, groups.length);
        foreach (g; groups) {
            leb128u(out_, g.count);
            out_ ~= cast(ubyte)g.type;
        }
    }
    
    /// Address mode for struct field initialization
    enum EmitAddrMode { fromSP, fromFP }

    // ─── Mixed-in method groups ─────────────────────────────────────
    mixin StatementEmitter;
    mixin ExpressionEmitter;
    mixin CallEmitter;
}
