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

        bool isStruct() const { return kind == VarKind.struct_; }
        bool isClass() const { return kind == VarKind.class_; }
        bool isInterface() const { return kind == VarKind.interface_; }
        bool isSlice() const { return kind == VarKind.slice; }
        bool isStaticArray() const { return kind == VarKind.staticArray; }
        bool isScalar() const { return kind == VarKind.scalar; }
    }

    VarInfo[uint] varsByLocalId;    // uniqueLocalId → VarInfo (primary lookup)
    VarInfo[string] varsByName;     // name → VarInfo (fallback for "this", legacy)

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

    /// Emit the base address of a variable onto the WASM stack.
    /// For wasmLocal/paramPointer: emits local_get.
    /// For shadowStack: emits FP + frameOffset.
    void emitVarAddress(ref Appender!(ubyte[]) out_, const VarInfo* info) {
        final switch (info.addrMode) {
            case AddrMode.wasmLocal:
            case AddrMode.paramPointer:
                out_ ~= Op.local_get;
                leb128u(out_, info.wasmLocalIdx);
                break;
            case AddrMode.shadowStack:
                // FP + frameOffset
                out_ ~= Op.local_get;
                leb128u(out_, fpLocal);
                out_ ~= Op.i32_const;
                leb128u(out_, info.frameOffset);
                out_ ~= Op.i32_add;
                break;
        }
    }

    uint frameSize = 0;        // Total size of struct/slice locals on shadow stack
    uint savedSpLocal;         // Local index to store saved SP (for epilogue restore)
    uint fpLocal;              // Local index for frame pointer (stable, never changes)
    uint tempLocalA;           // Temp local for aggregate copy (dst addr)
    uint tempLocalB;           // Temp local for aggregate copy (src addr)
    
    // Block depth for br instructions
    uint blockDepth = 0;

    // Loop stack for break/continue
    struct LoopContext {
        uint breakBlockDepth;     // blockDepth of the outer block (break target)
        uint continueBlockDepth;  // blockDepth of the loop/inner block (continue target)
    }
    LoopContext[] loopStack;

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
    
    this(FuncInfo f, BinaryEmitter e) {
        this.func = f;
        this.emitter = e;
        
        uint localOffset = 0;
        
        // For methods, add hidden 'this' pointer as first parameter
        if (f.structParent !is null) {
            localTypes ~= ValType.i32;  // 'this' is a pointer (i32)
            thisLocalIndex = 0;
            localOffset = 1;
            
            // Register 'this' as a struct param so this.x works
            VarInfo vi;
            vi.kind = VarKind.struct_;
            vi.addrMode = AddrMode.paramPointer;
            vi.wasmLocalIdx = 0;
            vi.structDecl = f.structParent;
            varsByLocalId[THIS_LOCAL_ID] = vi;
            varsByName["this"] = vi;
        }

        // Same for class methods
        if (f.classParent !is null) {
            localTypes ~= ValType.i32;  // 'this' is a pointer (i32)
            thisLocalIndex = 0;
            localOffset = 1;

            // Register 'this' as a class param so this.x works
            VarInfo vi;
            vi.kind = VarKind.class_;
            vi.addrMode = AddrMode.paramPointer;
            vi.wasmLocalIdx = 0;
            vi.classDecl = f.classParent;
            varsByLocalId[THIS_LOCAL_ID] = vi;
            varsByName["this"] = vi;
        }
        
        // Resolve return type if needed
        if (auto ut = cast(UserType)f.decl.returnType)
            ut.ensureResolved(e.symbolTable);

        // Check for large return type (struct or static array)
        hasLargeReturn = f.decl.returnType.isLargeReturn();
        if (hasLargeReturn) {
            // Hidden result pointer is the next parameter
            resultPtrLocalIdx = cast(uint)localTypes.length;
            localTypes ~= ValType.i32;  // Result pointer is i32
            localOffset++;

            // Calculate return value size
            if (auto arrType = cast(ArrayType)f.decl.returnType) {
                if (arrType.arraySize !is null) {
                    // Static array: elemSize * count
                    uint elemCount = evaluateStaticArraySize(arrType.arraySize);
                    size_t elemSize = arrType.elementType.size();
                    if (elemSize == 0) elemSize = 4;
                    returnValueSize = elemCount * cast(uint)elemSize;
                } else {
                    returnValueSize = sliceLayout.totalSize;  // Slice struct
                }
            } else if (auto sd = f.decl.returnType.asStruct()) {
                returnValueSize = cast(uint)sd.structSize;
            } else {
                returnValueSize = cast(uint)f.decl.returnType.size();
            }
        }
        
        // Register hidden arena parameter if function allocates.
        // Exported free functions (like "main") don't get the param — they use the global fallback.
        hasArenaParam = f.decl.needsArena && !(f.decl.name == "main" && f.structParent is null && f.classParent is null);
        if (hasArenaParam) {
            arenaLocalIdx = cast(uint)localTypes.length;
            localTypes ~= ValType.i32;  // Arena pointer is i32
            localOffset++;
        }

        // Parameters are the next locals
        // Use running wasmLocalIdx because interface params take 2 WASM locals
        uint wasmLocalIdx = localOffset;
        foreach (i, p; f.decl.parameters) {
            bool isInterfaceParam = false;
            InterfaceDecl ifaceDecl = null;
            
            // Check if this is an interface parameter (needs 2 locals)
            if (auto userType = cast(UserType)p.type) {
                userType.ensureResolved(e.symbolTable);
                ifaceDecl = userType.asInterface();
                isInterfaceParam = (ifaceDecl !is null);
            }
            
            if (isInterfaceParam) {
                // Interface: fat pointer = 2 i32 locals (obj_ptr, itable_ptr)
                localTypes ~= ValType.i32;
                localTypes ~= ValType.i32;

                VarInfo vi;
                vi.kind = VarKind.interface_;
                vi.addrMode = AddrMode.paramPointer;
                vi.wasmLocalIdx = wasmLocalIdx;
                vi.itableLocalIdx = wasmLocalIdx + 1;
                vi.type = p.type;
                vi.ifaceDecl = ifaceDecl;
                if (p.uniqueLocalId != uint.max)
                    varsByLocalId[p.uniqueLocalId] = vi;
                varsByName[p.name] = vi;

                wasmLocalIdx += 2;
            } else {
                auto vt = e.dTypeToValType(p.type);
                localTypes ~= vt;

                VarInfo vi;
                vi.wasmLocalIdx = wasmLocalIdx;
                vi.type = p.type;

                if (auto structDecl = p.type.asStruct()) {
                    vi.kind = VarKind.struct_;
                    vi.addrMode = AddrMode.paramPointer;
                    vi.structDecl = structDecl;
                } else if (auto classDecl = p.type.asClass()) {
                    vi.kind = VarKind.class_;
                    vi.addrMode = AddrMode.paramPointer;
                    vi.classDecl = classDecl;
                } else if (auto arrayType = cast(ArrayType)p.type) {
                    if (arrayType.arraySize !is null) {
                        // Static array param — passed as i32 pointer
                        vi.kind = VarKind.staticArray;
                        vi.addrMode = AddrMode.paramPointer;
                        vi.elementType = arrayType.elementType;
                        vi.elementCount = evaluateStaticArraySize(arrayType.arraySize);
                        vi.elementSize = wasmElementSize(arrayType.elementType);
                    } else {
                        // Dynamic array (slice)
                        vi.kind = VarKind.slice;
                        vi.addrMode = AddrMode.paramPointer;
                        vi.elementType = arrayType.elementType;
                        vi.elementSize = wasmElementSize(arrayType.elementType);
                    }
                } else {
                    // Scalar parameter
                    vi.kind = VarKind.scalar;
                    vi.addrMode = AddrMode.wasmLocal;
                }

                if (p.uniqueLocalId != uint.max)
                    varsByLocalId[p.uniqueLocalId] = vi;
                varsByName[p.name] = vi;

                wasmLocalIdx += 1;
            }
        }
        paramCount = wasmLocalIdx;
        
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

                // Class local - allocate on shadow stack (same as struct)
                if (auto classDecl = userType.asClass()) {
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

                // Interface local - allocate fat pointer on shadow stack (8 bytes)
                if (auto ifaceDecl = userType.asInterface()) {
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

            // Regular local - add to WASM locals
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
        throw new EmitError("Static array size must be a compile-time constant integer");
    }
    
    /**
     * Finalize locals after collection - add saved SP and FP locals if needed
     */
    void finalizeLocals() {
        if (frameSize > 0) {
            // Need locals for saved SP (epilogue restore) and FP (stable frame access)
            savedSpLocal = cast(uint)localTypes.length;
            localTypes ~= ValType.i32;
            fpLocal = cast(uint)localTypes.length;
            localTypes ~= ValType.i32;
            // Temp locals for aggregate copy (index assignment of structs, etc.)
            tempLocalA = cast(uint)localTypes.length;
            localTypes ~= ValType.i32;
            tempLocalB = cast(uint)localTypes.length;
            localTypes ~= ValType.i32;
        }

        // Methods on structs with slice fields need temp locals for emitSliceFieldAppend
        // even when frameSize == 0 (no struct/slice locals of their own).
        // Without this, tempLocalA defaults to 0 which aliases the 'this' parameter.
        if (frameSize == 0 && func.structParent !is null) {
            foreach (field; func.structParent.fields) {
                if (auto at = cast(ArrayType)field.type) {
                    if (!at.isStaticArray) {
                        tempLocalA = cast(uint)localTypes.length;
                        localTypes ~= ValType.i32;
                        tempLocalB = cast(uint)localTypes.length;
                        localTypes ~= ValType.i32;
                        break;
                    }
                }
            }
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
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.local_set;
        leb128u(out_, savedSpLocal);
        
        // $sp = $sp - frameSize
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, frameSize);
        out_ ~= Op.i32_sub;
        out_ ~= Op.global_set;
        leb128u(out_, emitter.spGlobal);
        
        // FP = $sp (frame pointer for stable local access)
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.local_set;
        leb128u(out_, fpLocal);
    }
    
    /**
     * Emit shadow stack epilogue (restores SP before implicit return)
     * 
     * $sp = savedSp
     */
    void emitEpilogue(ref Appender!(ubyte[]) out_) {
        // First, emit call stack pop if enabled
        if (enableStackTrace) {
            emitCallStackPop(out_);
        }

        if (frameSize == 0) return;

        // $sp = savedSp
        out_ ~= Op.local_get;
        leb128u(out_, savedSpLocal);
        out_ ~= Op.global_set;
        leb128u(out_, emitter.spGlobal);
    }

    /// Push the current arena pointer onto the WASM stack.
    /// Uses the function's hidden arena parameter if available,
    /// otherwise falls back to the global root arena.
    void emitArenaPointer(ref Appender!(ubyte[]) out_) {
        if (hasArenaParam) {
            out_ ~= Op.local_get;
            leb128u(out_, arenaLocalIdx);
        } else {
            out_ ~= Op.global_get;
            leb128u(out_, emitter.arenaBaseGlobal);
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
        out_ ~= Op.call;
        leb128u(out_, isNew ? emitter.arenaNewFuncIndex : emitter.arenaDropFuncIndex);
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
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_DEPTH_OFFSET);  // address 0
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;  // alignment = 4
        out_ ~= cast(ubyte)0x00;  // offset = 0
        
        // Check if depth < 64
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_MAX_FRAMES);
        out_ ~= Op.i32_lt_u;
        
        // if (depth < 64) {
        out_ ~= Op.if_;
        out_ ~= BlockType.void_;  // No result
        
        // Calculate frame address: 8 + depth * 24
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_FRAMES_OFFSET);
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_DEPTH_OFFSET);
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        out_ ~= cast(ubyte)0x00;
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_FRAME_SIZE);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;
        // Stack: [frameAddr]
        
        // Store nameOffset at frameAddr + 0
        out_ ~= Op.i32_const;
        leb128u(out_, frameNameOffset);
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        out_ ~= cast(ubyte)0x00;
        
        // Recalculate frameAddr for next store (depth still same)
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_FRAMES_OFFSET);
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_DEPTH_OFFSET);
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        out_ ~= cast(ubyte)0x00;
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_FRAME_SIZE);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;
        
        // Store nameLen at frameAddr + 4
        out_ ~= Op.i32_const;
        leb128u(out_, frameNameLen);
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        out_ ~= cast(ubyte)0x04;
        
        // Recalculate frameAddr
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_FRAMES_OFFSET);
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_DEPTH_OFFSET);
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        out_ ~= cast(ubyte)0x00;
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_FRAME_SIZE);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;
        
        // Store fileOffset at frameAddr + 8
        out_ ~= Op.i32_const;
        leb128u(out_, frameFileOffset);
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        out_ ~= cast(ubyte)0x08;
        
        // Recalculate frameAddr
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_FRAMES_OFFSET);
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_DEPTH_OFFSET);
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        out_ ~= cast(ubyte)0x00;
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_FRAME_SIZE);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;
        
        // Store fileLen at frameAddr + 12
        out_ ~= Op.i32_const;
        leb128u(out_, frameFileLen);
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        out_ ~= cast(ubyte)0x0C;
        
        // Recalculate frameAddr
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_FRAMES_OFFSET);
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_DEPTH_OFFSET);
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        out_ ~= cast(ubyte)0x00;
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_FRAME_SIZE);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;
        
        // Store line at frameAddr + 16
        out_ ~= Op.i32_const;
        leb128u(out_, frameLine);
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        out_ ~= cast(ubyte)0x10;
        
        // Recalculate frameAddr
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_FRAMES_OFFSET);
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_DEPTH_OFFSET);
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        out_ ~= cast(ubyte)0x00;
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_FRAME_SIZE);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;
        
        // Store column at frameAddr + 20
        out_ ~= Op.i32_const;
        leb128u(out_, frameColumn);
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        out_ ~= cast(ubyte)0x14;
        
        // Increment depth: mem[0] = mem[0] + 1
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_DEPTH_OFFSET);  // address for store
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_DEPTH_OFFSET);  // address for load
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        out_ ~= cast(ubyte)0x00;
        out_ ~= Op.i32_const;
        leb128u(out_, 1);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        out_ ~= cast(ubyte)0x00;
        
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
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_DEPTH_OFFSET);  // address for store
        out_ ~= Op.i32_const;
        leb128u(out_, CALL_STACK_DEPTH_OFFSET);  // address for load
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        out_ ~= cast(ubyte)0x00;
        out_ ~= Op.i32_const;
        leb128u(out_, 1);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        out_ ~= cast(ubyte)0x00;
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
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128u(out_, info.frameOffset);
        out_ ~= Op.i32_add;
        
        // Call the destructor
        string dtorName = info.structDecl.name ~ "_~this";
        if (auto funcIdx = dtorName in emitter.funcIndex) {
            out_ ~= Op.call;
            leb128u(out_, *funcIdx);
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
    
    //==========================================================================
    // Statement Emission
    //==========================================================================
    
    void emitStatement(ref Appender!(ubyte[]) out_, Statement stmt) {
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                emitStatement(out_, s);
            }
            // Emit destructor calls for variables going out of scope (RAII)
            emitScopeDestructors(out_, compound.destructOnExit);
        } else if (auto returnStmt = cast(ReturnStatement)stmt) {
            emitReturn(out_, returnStmt);
        } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
            emitExpressionStatement(out_, exprStmt);
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            emitIf(out_, ifStmt);
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            emitWhile(out_, whileStmt);
        } else if (auto forStmt = cast(ForStatement)stmt) {
            emitFor(out_, forStmt);
        } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
            // Check if this is an aggregate local (on shadow stack)
            if (auto info = resolveVar(varDecl.uniqueLocalId, varDecl.name)) {
                final switch (info.kind) {
                    case VarKind.struct_:     emitStructVarDecl(out_, varDecl); break;
                    case VarKind.class_:      emitClassVarDecl(out_, varDecl); break;
                    case VarKind.interface_:  emitInterfaceVarDecl(out_, varDecl); break;
                    case VarKind.staticArray: emitStaticArrayVarDecl(out_, varDecl); break;
                    case VarKind.slice:       emitSliceVarDecl(out_, varDecl); break;
                    case VarKind.scalar:      emitVarDecl(out_, varDecl); break;
                }
            } else {
                emitVarDecl(out_, varDecl);
            }
        } else if (cast(BreakStatement)stmt) {
            if (loopStack.length == 0)
                throw new EmitError("break statement outside of loop");
            auto ctx = loopStack[$ - 1];
            out_ ~= Op.br;
            leb128u(out_, blockDepth - ctx.breakBlockDepth);
        } else if (cast(ContinueStatement)stmt) {
            if (loopStack.length == 0)
                throw new EmitError("continue statement outside of loop");
            auto ctx = loopStack[$ - 1];
            out_ ~= Op.br;
            leb128u(out_, blockDepth - ctx.continueBlockDepth);
        } else if (cast(StructDeclarationStatement)stmt) {
            // Inner struct declaration — no runtime code; methods already collected by emitter
        } else {
            throw new EmitError("Unsupported statement type", stmt.toString());
        }
    }
    
    void emitReturn(ref Appender!(ubyte[]) out_, ReturnStatement stmt) {
        if (hasLargeReturn && stmt.value) {
            // Large return: copy value to hidden result pointer
            emitLargeReturnCopy(out_, stmt.value);

            // Call destructors for all scopes being unwound (RAII)
            emitUnwindDestructors(out_, stmt.unwindChain);

            // Restore arena watermark before returning
            emitArenaScopeCall(out_, false);

            // Restore shadow stack before returning (void return)
            emitEpilogue(out_);
            out_ ~= Op.return_;
        } else {
            // Regular return
            if (stmt.value) {
                emitExpression(out_, stmt.value);
            }

            // Call destructors for all scopes being unwound (RAII)
            emitUnwindDestructors(out_, stmt.unwindChain);

            // Restore arena watermark before returning
            emitArenaScopeCall(out_, false);

            // Restore shadow stack before returning
            emitEpilogue(out_);
            out_ ~= Op.return_;
        }
    }
    
    /**
     * Copy a large return value to the hidden result pointer.
     * Works for structs and static arrays.
     */
    void emitLargeReturnCopy(ref Appender!(ubyte[]) out_, Expression value) {
        // Get source address onto stack
        // For identifiers (struct/array locals), emitExpression gives us the address
        // For struct literals or array literals, we'd need to handle separately
        
        if (auto ident = cast(IdentifierExpression)value) {
            // Check if it's a struct or static array local (on shadow stack)
            if (auto info = resolveVar(ident.resolvedLocalId, ident.name)) {
                if ((info.isStruct || info.isStaticArray || info.isSlice) && info.addrMode == AddrMode.shadowStack) {
                    emitMemoryCopy(out_, resultPtrLocalIdx, info.frameOffset, returnValueSize);
                    return;
                }
            }
        }
        
        // Fallback: emit expression (gets address), then copy
        // This handles cases like returning a field or more complex expressions
        emitExpression(out_, value);  // Stack: [src_addr]
        
        // For now, assume it's an address and copy
        // dst = result pointer, src = top of stack
        // We need to pop src into a temp, then do the copy
        
        // Store src address to pre-allocated temp local
        out_ ~= Op.local_set;
        leb128u(out_, returnTempLocalIdx);
        
        // Now copy from temp to result pointer
        emitMemoryCopyFromLocal(out_, resultPtrLocalIdx, returnTempLocalIdx, returnValueSize);
    }
    
    /**
     * Emit memory copy from frame offset to result pointer.
     */
    void emitMemoryCopy(ref Appender!(ubyte[]) out_, uint dstLocalIdx, uint srcFrameOffset, uint size) {
        // Copy 4 bytes at a time (assuming aligned)
        // For each 4-byte chunk:
        //   1. Push dst address (result ptr + offset)
        //   2. Load value from src (FP + srcOffset + offset)
        //   3. Store
        
        for (uint offset = 0; offset < size; offset += 4) {
            // Dst address
            out_ ~= Op.local_get;
            leb128u(out_, dstLocalIdx);
            if (offset > 0) {
                out_ ~= Op.i32_const;
                leb128s(out_, offset);
                out_ ~= Op.i32_add;
            }
            
            // Src value
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, srcFrameOffset + offset);
            out_ ~= Op.i32_add;
            out_ ~= Op.i32_load;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            
            // Store: [dst_addr, value] -> memory
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
        }
    }
    
    /**
     * Emit memory copy from one local (address) to another.
     */
    void emitMemoryCopyFromLocal(ref Appender!(ubyte[]) out_, uint dstLocalIdx, uint srcLocalIdx, uint size) {
        for (uint offset = 0; offset < size; offset += 4) {
            // Dst address
            out_ ~= Op.local_get;
            leb128u(out_, dstLocalIdx);
            if (offset > 0) {
                out_ ~= Op.i32_const;
                leb128s(out_, offset);
                out_ ~= Op.i32_add;
            }
            
            // Src value
            out_ ~= Op.local_get;
            leb128u(out_, srcLocalIdx);
            if (offset > 0) {
                out_ ~= Op.i32_const;
                leb128s(out_, offset);
                out_ ~= Op.i32_add;
            }
            out_ ~= Op.i32_load;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            
            // Store
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
        }
    }
    
    void emitExpressionStatement(ref Appender!(ubyte[]) out_, ExpressionStatement stmt) {
        emitExpression(out_, stmt.expression);
        
        // Drop result if expression leaves a value
        if (expressionHasValue(stmt.expression)) {
            out_ ~= Op.drop;
        }
    }
    
    void emitIf(ref Appender!(ubyte[]) out_, IfStatement stmt) {
        // Condition
        emitExpression(out_, stmt.condition);
        
        // if (void block type)
        out_ ~= Op.if_;
        out_ ~= cast(ubyte)BlockType.void_;
        blockDepth++;
        
        // Then branch
        emitStatement(out_, stmt.thenStatement);
        
        // Else branch
        if (stmt.elseStatement) {
            out_ ~= Op.else_;
            emitStatement(out_, stmt.elseStatement);
        }
        
        blockDepth--;
        out_ ~= Op.end;
        
        // If both branches return, code after this is unreachable
        // We need to tell WASM that to satisfy type checking
        if (stmt.elseStatement && 
            alwaysReturns(stmt.thenStatement) && 
            alwaysReturns(stmt.elseStatement)) {
            out_ ~= Op.unreachable;
        }
    }
    
    /**
     * Check if a statement always terminates (return, unreachable, etc.)
     */
    bool alwaysReturns(Statement stmt) {
        if (auto returnStmt = cast(ReturnStatement)stmt) {
            return true;
        }
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                if (alwaysReturns(s)) return true;
            }
            return false;
        }
        if (auto ifStmt = cast(IfStatement)stmt) {
            // if/else returns only if BOTH branches return
            return ifStmt.elseStatement !is null &&
                   alwaysReturns(ifStmt.thenStatement) &&
                   alwaysReturns(ifStmt.elseStatement);
        }
        // Statements that don't return
        if (cast(ExpressionStatement)stmt || cast(VariableDeclarationStatement)stmt
            || cast(WhileStatement)stmt || cast(ForStatement)stmt
            || cast(BreakStatement)stmt || cast(ContinueStatement)stmt
            || cast(MixinStatement)stmt || cast(StructDeclarationStatement)stmt) {
            return false;
        }
        assert(0, "alwaysReturns: unhandled statement type: " ~ typeid(stmt).name);
    }
    
    void emitWhile(ref Appender!(ubyte[]) out_, WhileStatement stmt) {
        // block (for break)
        out_ ~= Op.block;
        out_ ~= cast(ubyte)BlockType.void_;
        blockDepth++;
        uint breakDepth = blockDepth;

        // loop (for continue)
        out_ ~= Op.loop;
        out_ ~= cast(ubyte)BlockType.void_;
        blockDepth++;
        uint continueDepth = blockDepth;

        loopStack ~= LoopContext(breakDepth, continueDepth);

        // Condition
        emitExpression(out_, stmt.condition);
        out_ ~= Op.i32_eqz;  // Invert: break if false
        out_ ~= Op.br_if;
        leb128u(out_, 1);  // Break to outer block

        // Body
        emitStatement(out_, stmt.body_);

        // Continue: branch back to loop
        out_ ~= Op.br;
        leb128u(out_, 0);  // Back to loop

        loopStack = loopStack[0 .. $ - 1];

        blockDepth--;
        out_ ~= Op.end;  // End loop

        blockDepth--;
        out_ ~= Op.end;  // End block
    }
    
    void emitFor(ref Appender!(ubyte[]) out_, ForStatement stmt) {
        // Init
        if (stmt.init) {
            emitStatement(out_, stmt.init);
        }

        // block (for break)
        out_ ~= Op.block;
        out_ ~= cast(ubyte)BlockType.void_;
        blockDepth++;
        uint breakDepth = blockDepth;

        // loop
        out_ ~= Op.loop;
        out_ ~= cast(ubyte)BlockType.void_;
        blockDepth++;

        // Condition (if present)
        if (stmt.condition) {
            emitExpression(out_, stmt.condition);
            out_ ~= Op.i32_eqz;
            out_ ~= Op.br_if;
            leb128u(out_, 1);  // Break to outer block
        }

        // Inner block (continue target — exiting falls through to update)
        out_ ~= Op.block;
        out_ ~= cast(ubyte)BlockType.void_;
        blockDepth++;
        uint continueDepth = blockDepth;

        loopStack ~= LoopContext(breakDepth, continueDepth);

        // Body
        emitStatement(out_, stmt.body_);

        loopStack = loopStack[0 .. $ - 1];

        blockDepth--;
        out_ ~= Op.end;  // End inner block (continue lands here)

        // Update
        if (stmt.update) {
            emitExpression(out_, stmt.update);
            if (expressionHasValue(stmt.update)) {
                out_ ~= Op.drop;
            }
        }

        // Loop back
        out_ ~= Op.br;
        leb128u(out_, 0);

        blockDepth--;
        out_ ~= Op.end;  // End loop

        blockDepth--;
        out_ ~= Op.end;  // End block
    }
    
    void emitVarDecl(ref Appender!(ubyte[]) out_, VariableDeclarationStatement stmt) {
        auto info = resolveVar(stmt.uniqueLocalId, stmt.name);
        if (!info || info.addrMode != AddrMode.wasmLocal) {
            throw new EmitError("emitVarDecl: expected scalar local: " ~ stmt.name);
        }

        if (stmt.initializer) {
            emitExpression(out_, stmt.initializer);
        } else {
            out_ ~= Op.i32_const;
            leb128s(out_, 0);
        }

        out_ ~= Op.local_set;
        leb128u(out_, info.wasmLocalIdx);
    }
    
    /**
     * Emit struct local variable declaration - stores fields to shadow stack
     */
    void emitStructVarDecl(ref Appender!(ubyte[]) out_, VariableDeclarationStatement stmt) {
        auto infoPtr = resolveVar(stmt.uniqueLocalId, stmt.name);
        assert(infoPtr !is null && infoPtr.isStruct, "Expected struct local: " ~ stmt.name);
        auto info = *infoPtr;
        auto structDecl = info.structDecl;
        
        if (!stmt.initializer) {
            // Zero-initialize the struct (handle multi-word fields like slices)
            foreach (field; structDecl.fields) {
                uint fieldBytes = cast(uint)field.size;
                for (uint off = 0; off < fieldBytes; off += 4) {
                    // Address: FP + frameOffset + fieldOffset + off
                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.frameOffset + cast(int)field.offset + cast(int)off);
                    out_ ~= Op.i32_add;

                    // Value: 0
                    out_ ~= Op.i32_const;
                    leb128s(out_, 0);

                    // Store
                    out_ ~= Op.i32_store;
                    out_ ~= cast(ubyte)0x02;  // alignment log2(4)
                    leb128u(out_, 0);          // offset
                }
            }
            return;
        }
        
        // Struct construction or function call returning struct
        if (auto callExpr = cast(CallExpression)stmt.initializer) {
            if (auto ident = cast(IdentifierExpression)callExpr.function_) {
                auto sym = emitter.symbolTable.lookupSymbol(ident.name);
                if (sym && sym.kind == SymbolKind.Type) {
                    // Struct construction: Point(10, 20) or Outer(Inner(1,2), 3)
                    // Guard against opCall overloads (not yet supported)
                    if (auto sd = sym.type.asStruct()) {
                        foreach (member; sd.members) {
                            if (auto fd = cast(FunctionDecl)member) {
                                assert(fd.name != "opCall",
                                    "opCall overloads not yet supported");
                            }
                        }
                    }
                    emitStructFieldsInit(out_, structDecl, callExpr.arguments,
                                        EmitAddrMode.fromFP, info.frameOffset);
                    return;
                }
                // Function call returning aggregate — pass struct local's
                // frame address directly as hidden result pointer
                emitStructReturnCall(out_, ident.name, callExpr.arguments, info.frameOffset);
                return;
            }
            // Fallback: assume struct construction (e.g. complex expression as target)
            emitStructFieldsInit(out_, structDecl, callExpr.arguments,
                                EmitAddrMode.fromFP, info.frameOffset);
            return;
        }
        
        // Struct template construction: Pair!(int, int)(10, 20)
        if (auto tmplInst = cast(TemplateInstantiationExpression)stmt.initializer) {
            if (tmplInst.resolvedStructInstantiation) {
                emitStructFieldsInit(out_, structDecl, tmplInst.callArguments,
                                    EmitAddrMode.fromFP, info.frameOffset);
                return;
            }
        }

        // Struct copy: Point b = a (copy from another struct variable)
        if (auto identExpr = cast(IdentifierExpression)stmt.initializer) {
            // Check if source is a local struct
            if (auto srcInfo = resolveVar(identExpr.resolvedLocalId, identExpr.name)) if (srcInfo.isStruct) {
                // Copy field by field from source to destination
                for (size_t i = 0; i < structDecl.fields.length; i++) {
                    auto field = structDecl.fields[i];
                    
                    // Destination address: FP + destOffset + fieldOffset
                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.frameOffset + cast(int)field.offset);
                    out_ ~= Op.i32_add;
                    
                    // Source value: load from FP + srcOffset + fieldOffset
                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, srcInfo.frameOffset + cast(int)field.offset);
                    out_ ~= Op.i32_add;
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    
                    // Store to destination
                    out_ ~= Op.i32_store;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                }
                return;
            }
            
            // TODO: copy from global struct
        }
        
        throw new EmitError("Unsupported struct initializer", stmt.initializer.toString());
    }
    
    /**
     * Emit class local variable declaration.
     * Classes are laid out like structs but with vtable_ptr at offset 0.
     * For now, vtable_ptr is zeroed (no virtual dispatch yet).
     */
    void emitClassVarDecl(ref Appender!(ubyte[]) out_, VariableDeclarationStatement stmt) {
        auto infoPtr = resolveVar(stmt.uniqueLocalId, stmt.name);
        assert(infoPtr !is null && infoPtr.isClass, "Expected class local: " ~ stmt.name);
        auto info = *infoPtr;
        auto classDecl = info.classDecl;
        
        // Initialize vtable_ptr at offset 0 with packed value:
        // vtable_ptr = (typeId << TYPE_ID_SHIFT) | tableBase
        // - typeId: for RTTI / error messages
        // - tableBase: starting index in function table for virtual dispatch
        uint packedVtablePtr = WasmVtablePacking.pack(classDecl.typeId, classDecl.tableBase);
        
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, info.frameOffset);  // offset 0 = vtable_ptr
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_const;
        leb128s(out_, cast(int)packedVtablePtr);
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        if (!stmt.initializer) {
            // Zero-initialize all fields
            foreach (field; classDecl.fields) {
                out_ ~= Op.local_get;
                leb128u(out_, fpLocal);
                out_ ~= Op.i32_const;
                leb128s(out_, info.frameOffset + cast(int)field.offset);
                out_ ~= Op.i32_add;
                out_ ~= Op.i32_const;
                leb128s(out_, 0);
                out_ ~= Op.i32_store;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
            }
            return;
        }
        
        // Constructor call: Dog(42)
        if (auto callExpr = cast(CallExpression)stmt.initializer) {
            // Initialize fields from constructor arguments (same as struct)
            for (size_t i = 0; i < classDecl.fields.length && i < callExpr.arguments.length; i++) {
                auto field = classDecl.fields[i];
                out_ ~= Op.local_get;
                leb128u(out_, fpLocal);
                out_ ~= Op.i32_const;
                leb128s(out_, info.frameOffset + cast(int)field.offset);
                out_ ~= Op.i32_add;
                emitExpression(out_, callExpr.arguments[i]);
                out_ ~= Op.i32_store;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
            }
            return;
        }
        
        // Copy from another class local: Dog b = a
        if (auto identExpr = cast(IdentifierExpression)stmt.initializer) {
            if (auto srcInfo = resolveVar(identExpr.resolvedLocalId, identExpr.name)) if (srcInfo.isClass) {
                // Copy entire class including vtable_ptr
                uint totalSize = cast(uint)classDecl.classSize;
                for (uint offset = 0; offset < totalSize; offset += 4) {
                    // Dst address
                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.frameOffset + offset);
                    out_ ~= Op.i32_add;
                    // Src value
                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, srcInfo.frameOffset + offset);
                    out_ ~= Op.i32_add;
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    // Store
                    out_ ~= Op.i32_store;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                }
                return;
            }
        }
        
        throw new EmitError("Unsupported class initializer", stmt.initializer.toString());
    }
    
    /**
     * Emit interface local variable declaration
     * Fat pointer layout: { obj_ptr: i32, itable_ptr: i32 } = 8 bytes
     */
    void emitInterfaceVarDecl(ref Appender!(ubyte[]) out_, VariableDeclarationStatement stmt) {
        auto infoPtr = resolveVar(stmt.uniqueLocalId, stmt.name);
        assert(infoPtr !is null && infoPtr.isInterface, "Expected interface local: " ~ stmt.name);
        auto info = *infoPtr;
        
        if (!stmt.initializer) {
            // Zero-initialize the fat pointer (obj_ptr=0, itable_ptr=0)
            // obj_ptr at offset 0
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, info.frameOffset);
            out_ ~= Op.i32_add;
            out_ ~= Op.i32_const;
            leb128s(out_, 0);
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            
            // itable_ptr at offset 4
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, info.frameOffset + sliceLayout.lengthOffset);
            out_ ~= Op.i32_add;
            out_ ~= Op.i32_const;
            leb128s(out_, 0);
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            return;
        }
        
        // Initializer is a class reference: ISpeak s = dog;
        // Need to create fat pointer: {obj_ptr, itable_ptr}
        if (auto identExpr = cast(IdentifierExpression)stmt.initializer) {
            ClassDecl srcClass = null;
            
            // Determine source class and emit obj_ptr store
            if (auto srcVar = resolveVar(identExpr.resolvedLocalId, identExpr.name)) {
                if (srcVar.isClass) {
                    srcClass = srcVar.classDecl;

                    // Store obj_ptr: dest = FP + info.frameOffset, src = srcVar address
                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.frameOffset);  // dest
                    out_ ~= Op.i32_add;

                    emitVarAddress(out_, srcVar);  // src obj addr

                    out_ ~= Op.i32_store;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                }
            } else {
                throw new EmitError("Unknown class for interface assignment: " ~ identExpr.name);
            }
            
            // Now store itable_ptr at offset 4
            if (srcClass) {
                // Look up itable base for this interface
                string ifaceName = info.ifaceDecl.name;
                if (auto itableBase = ifaceName in srcClass.itableBases) {
                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.frameOffset + sliceLayout.lengthOffset);
                    out_ ~= Op.i32_add;
                    
                    out_ ~= Op.i32_const;
                    leb128s(out_, cast(int)*itableBase);
                    
                    out_ ~= Op.i32_store;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                } else {
                    throw new EmitError("Class " ~ srcClass.name ~ " has no itable for interface " ~ ifaceName);
                }
            }
            return;
        }
        
        // Handle cast expression: ISpeak s = cast(ISpeak)dog;
        if (auto castExpr = cast(CastExpression)stmt.initializer) {
            if (castExpr.sourceClassDecl && castExpr.targetInterfaceDecl) {
                // Extract inner identifier and use same logic
                if (auto identExpr = cast(IdentifierExpression)castExpr.expression) {
                    ClassDecl srcClass = castExpr.sourceClassDecl;
                    
                    // Store obj_ptr at offset 0
                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.frameOffset);
                    out_ ~= Op.i32_add;
                    
                    if (auto srcInfo = resolveVar(identExpr.resolvedLocalId, identExpr.name)) {
                        if (srcInfo.isClass) {
                            emitVarAddress(out_, srcInfo);
                        }
                    } else {
                        throw new EmitError("Unknown class in cast: " ~ identExpr.name);
                    }
                    
                    out_ ~= Op.i32_store;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    
                    // Store itable_ptr at offset 4
                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.frameOffset + sliceLayout.lengthOffset);
                    out_ ~= Op.i32_add;
                    
                    string ifaceName = castExpr.targetInterfaceDecl.name;
                    if (auto itableBase = ifaceName in srcClass.itableBases) {
                        out_ ~= Op.i32_const;
                        leb128s(out_, cast(int)*itableBase);
                    } else {
                        throw new EmitError("Class " ~ srcClass.name ~ " has no itable for " ~ ifaceName);
                    }
                    
                    out_ ~= Op.i32_store;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    
                    return;
                }
            }
        }
        
        throw new EmitError("Unsupported interface initializer");
    }
    
    /**
     * Emit slice local variable declaration
     * Slice struct layout: { ptr: i32, length: i32, capacity: i32 } = sliceLayout.totalSize bytes
     */
    void emitSliceVarDecl(ref Appender!(ubyte[]) out_, VariableDeclarationStatement stmt) {
        auto infoPtr = resolveVar(stmt.uniqueLocalId, stmt.name);
        assert(infoPtr !is null && infoPtr.isSlice, "Expected slice local: " ~ stmt.name);
        auto info = *infoPtr;
        
        if (!stmt.initializer) {
            // Zero-initialize the slice struct (ptr=0, length=0, capacity=0)
            for (int offset = 0; offset < 12; offset += 4) {
                out_ ~= Op.local_get;
                leb128u(out_, fpLocal);
                out_ ~= Op.i32_const;
                leb128s(out_, info.frameOffset + offset);
                out_ ~= Op.i32_add;
                out_ ~= Op.i32_const;
                leb128s(out_, 0);
                out_ ~= Op.i32_store;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
            }
            return;
        }
        
        // Array literal initializer: [1, 2, 3]
        if (auto arrayLit = cast(ArrayLiteralExpression)stmt.initializer) {
            uint elemCount = cast(uint)arrayLit.elements.length;
            size_t elemSize = info.elementType ? info.elementType.size() : 4;
            if (elemSize == 0) elemSize = 4;
            
            // First, store the data elements at FP + dataOffset
            for (uint i = 0; i < elemCount; i++) {
                // Address: FP + dataOffset + i * elemSize
                out_ ~= Op.local_get;
                leb128u(out_, fpLocal);
                out_ ~= Op.i32_const;
                leb128s(out_, info.dataOffset + cast(int)(i * elemSize));
                out_ ~= Op.i32_add;
                
                // Value: the element expression
                emitExpression(out_, arrayLit.elements[i]);

                // Store
                emitStoreForSize(out_, cast(uint)elemSize);
            }
            
            // Now initialize the slice struct:
            // ptr = FP + dataOffset
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, info.frameOffset);  // slice.ptr offset = 0
            out_ ~= Op.i32_add;
            
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, info.dataOffset);
            out_ ~= Op.i32_add;  // ptr value = FP + dataOffset
            
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            
            // length = elemCount
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, info.frameOffset + sliceLayout.lengthOffset);  // slice.length offset = 4
            out_ ~= Op.i32_add;
            
            out_ ~= Op.i32_const;
            leb128s(out_, elemCount);
            
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            
            // capacity = elemCount
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, info.frameOffset + sliceLayout.capacityOffset);  // slice.capacity offset = 8
            out_ ~= Op.i32_add;
            
            out_ ~= Op.i32_const;
            leb128s(out_, elemCount);
            
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            
            return;
        }
        
        // String literal initializer: "hello" -> ubyte[]
        if (auto literal = cast(LiteralExpression)stmt.initializer) {
            if (literal.value.type == typeid(string)) {
                string strVal = literal.value.get!string();
                uint structAddr = emitter.registerArrayLiteral(strVal);
                uint len = cast(uint)strVal.length;
                
                // Load ptr from data section struct
                out_ ~= Op.local_get;
                leb128u(out_, fpLocal);
                out_ ~= Op.i32_const;
                leb128s(out_, info.frameOffset);  // slice.ptr offset = 0
                out_ ~= Op.i32_add;
                
                out_ ~= Op.i32_const;
                leb128u(out_, structAddr);
                out_ ~= Op.i32_load;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
                
                out_ ~= Op.i32_store;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
                
                // length
                out_ ~= Op.local_get;
                leb128u(out_, fpLocal);
                out_ ~= Op.i32_const;
                leb128s(out_, info.frameOffset + sliceLayout.lengthOffset);  // slice.length offset = 4
                out_ ~= Op.i32_add;
                
                out_ ~= Op.i32_const;
                leb128s(out_, len);
                
                out_ ~= Op.i32_store;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
                
                // capacity = length (immutable string data)
                out_ ~= Op.local_get;
                leb128u(out_, fpLocal);
                out_ ~= Op.i32_const;
                leb128s(out_, info.frameOffset + sliceLayout.capacityOffset);  // slice.capacity offset = 8
                out_ ~= Op.i32_add;
                
                out_ ~= Op.i32_const;
                leb128s(out_, len);
                
                out_ ~= Op.i32_store;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
                
                return;
            }
        }
        
        // Import expression initializer: import("file.txt") -> ubyte[]
        if (auto importExpr = cast(ImportExpression)stmt.initializer) {
            import std.file : read, exists;
            import std.path : buildPath, dirName;
            
            string filename = importExpr.filename;
            string sourcePath = importExpr.location.filename;
            string sourceDir = sourcePath.length > 0 ? dirName(sourcePath) : ".";
            string fullPath = buildPath(sourceDir, filename);
            
            if (!exists(fullPath)) fullPath = filename;
            
            if (!exists(fullPath)) {
                throw new EmitError("import(): file not found: " ~ filename);
            }
            
            ubyte[] fileData = cast(ubyte[])read(fullPath);
            uint len = cast(uint)fileData.length;
            
            // Add file data to data section
            uint dataOffset = emitter.addData(fileData);
            
            // Initialize slice struct: ptr = dataOffset, length = len, capacity = len
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, info.frameOffset);
            out_ ~= Op.i32_add;
            out_ ~= Op.i32_const;
            leb128s(out_, dataOffset);
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, info.frameOffset + sliceLayout.lengthOffset);
            out_ ~= Op.i32_add;
            out_ ~= Op.i32_const;
            leb128s(out_, len);
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, info.frameOffset + sliceLayout.capacityOffset);
            out_ ~= Op.i32_add;
            out_ ~= Op.i32_const;
            leb128s(out_, len);
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            
            return;
        }
        
        // Slice expression initializer: arr[1..3]
        if (auto sliceExpr = cast(SliceExpression)stmt.initializer) {
            auto sourceIdent = cast(IdentifierExpression)sliceExpr.array;
            if (!sourceIdent) {
                throw new EmitError("Complex slice source not supported");
            }
            
            auto sourceInfo = resolveVar(sourceIdent.resolvedLocalId, sourceIdent.name);
            if (!sourceInfo || (!sourceInfo.isSlice && !sourceInfo.isStaticArray)) {
                throw new EmitError("Can only slice local arrays for now");
            }

            // Calculate ptr = base + start * elemSize
            // Store at FP + frameOffset (slice.ptr)
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, info.frameOffset);
            out_ ~= Op.i32_add;

            // Load base address
            if (sourceInfo.isSlice) {
                // Slice source: load .ptr field
                emitVarAddress(out_, sourceInfo);
                out_ ~= Op.i32_load;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
            } else {
                // Static array source: address IS the data
                emitVarAddress(out_, sourceInfo);
            }
            
            // Add start * elemSize
            emitExpression(out_, sliceExpr.start);
            out_ ~= Op.i32_const;
            leb128s(out_, sourceInfo.elementSize);
            out_ ~= Op.i32_mul;
            out_ ~= Op.i32_add;
            
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            
            // Calculate length = end - start
            // Store at FP + frameOffset + 4 (slice.length at LENGTH_OFFSET)
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, info.frameOffset + sliceLayout.lengthOffset);
            out_ ~= Op.i32_add;
            
            emitExpression(out_, sliceExpr.end);
            emitExpression(out_, sliceExpr.start);
            out_ ~= Op.i32_sub;
            
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            
            // Set capacity = length (can't safely grow a view)
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, info.frameOffset + sliceLayout.capacityOffset);
            out_ ~= Op.i32_add;
            
            emitExpression(out_, sliceExpr.end);
            emitExpression(out_, sliceExpr.start);
            out_ ~= Op.i32_sub;
            
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            
            return;
        }
        
        // Function call returning a slice — same hidden result pointer pattern as structs
        if (auto callExpr = cast(CallExpression)stmt.initializer) {
            if (auto ident = cast(IdentifierExpression)callExpr.function_) {
                emitStructReturnCall(out_, ident.name, callExpr.arguments, info.frameOffset);
                return;
            }
        }

        // Manifest array constant initializer: int[] x = MANIFEST_ARR;
        if (auto ident = cast(IdentifierExpression)stmt.initializer) {
            auto symbol = emitter.symbolTable.lookupSymbol(ident.name);
            if (symbol && symbol.isConstant) {
                if (auto manifest = cast(ManifestConstantDecl)symbol.declaration) {
                    if (manifest.isArrayType || manifest.isNestedArrayType) {
                        if (!manifest.ctfeComplete)
                            emitter.symbolTable.ensureManifestEvaluated(manifest);
                        uint structAddr = manifest.isNestedArrayType
                            ? emitter.registerManifestNestedArray(manifest)
                            : emitter.registerManifestArray(manifest);
                        // Copy 12-byte {ptr, len, cap} struct to frame
                        // ptr field
                        out_ ~= Op.local_get;
                        leb128u(out_, fpLocal);
                        out_ ~= Op.i32_const;
                        leb128s(out_, info.frameOffset);
                        out_ ~= Op.i32_add;
                        out_ ~= Op.i32_const;
                        leb128s(out_, structAddr);
                        out_ ~= Op.i32_load;
                        out_ ~= cast(ubyte)0x02;
                        leb128u(out_, 0);
                        out_ ~= Op.i32_store;
                        out_ ~= cast(ubyte)0x02;
                        leb128u(out_, 0);
                        // len field
                        out_ ~= Op.local_get;
                        leb128u(out_, fpLocal);
                        out_ ~= Op.i32_const;
                        leb128s(out_, info.frameOffset + sliceLayout.lengthOffset);
                        out_ ~= Op.i32_add;
                        out_ ~= Op.i32_const;
                        leb128s(out_, structAddr + sliceLayout.lengthOffset);
                        out_ ~= Op.i32_load;
                        out_ ~= cast(ubyte)0x02;
                        leb128u(out_, 0);
                        out_ ~= Op.i32_store;
                        out_ ~= cast(ubyte)0x02;
                        leb128u(out_, 0);
                        // cap field
                        out_ ~= Op.local_get;
                        leb128u(out_, fpLocal);
                        out_ ~= Op.i32_const;
                        leb128s(out_, info.frameOffset + sliceLayout.capacityOffset);
                        out_ ~= Op.i32_add;
                        out_ ~= Op.i32_const;
                        leb128s(out_, structAddr + sliceLayout.capacityOffset);
                        out_ ~= Op.i32_load;
                        out_ ~= cast(ubyte)0x02;
                        leb128u(out_, 0);
                        out_ ~= Op.i32_store;
                        out_ ~= cast(ubyte)0x02;
                        leb128u(out_, 0);
                        return;
                    }
                }
            }
        }

        throw new EmitError("Unsupported slice initializer", stmt.initializer.toString());
    }

    /**
     * Emit a slice expression to a 12-byte temp on the SP-based stack.
     * Pushes the temp's i32 address onto the WASM value stack.
     * Handles both slice and static array sources.
     */
    void emitSliceExpressionToTemp(ref Appender!(ubyte[]) out_, SliceExpression sliceExpr) {
        auto sourceIdent = cast(IdentifierExpression)sliceExpr.array;
        if (!sourceIdent)
            throw new EmitError("Complex slice source not supported");
        auto srcInfo = resolveVar(sourceIdent.resolvedLocalId, sourceIdent.name);
        if (!srcInfo || (!srcInfo.isSlice && !srcInfo.isStaticArray))
            throw new EmitError("Can only slice array-like variables");
        uint elemSize = srcInfo.elementSize;
        const sliceSize = sliceLayout.totalSize;  // 12

        // Allocate temp: SP -= 12
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceSize);
        out_ ~= Op.i32_sub;
        out_ ~= Op.global_set;
        leb128u(out_, emitter.spGlobal);

        // Store ptr = base + start * elemSize at SP+0
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        if (srcInfo.isSlice) {
            emitVarAddress(out_, srcInfo);
            out_ ~= Op.i32_load;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);  // load .ptr field
        } else {
            // static array: address IS the data
            emitVarAddress(out_, srcInfo);
        }
        emitExpression(out_, sliceExpr.start);
        out_ ~= Op.i32_const;
        leb128s(out_, elemSize);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);

        // Store length = end - start at SP+LENGTH_OFFSET
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceLayout.lengthOffset);
        out_ ~= Op.i32_add;
        emitExpression(out_, sliceExpr.end);
        emitExpression(out_, sliceExpr.start);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);

        // Store capacity = length at SP+CAPACITY_OFFSET
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceLayout.capacityOffset);
        out_ ~= Op.i32_add;
        emitExpression(out_, sliceExpr.end);
        emitExpression(out_, sliceExpr.start);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);

        // Push temp address
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
    }

    /**
     * Emit static array local variable declaration
     * Static arrays are stored directly on the shadow stack (no slice struct)
     */
    void emitStaticArrayVarDecl(ref Appender!(ubyte[]) out_, VariableDeclarationStatement stmt) {
        auto infoPtr = resolveVar(stmt.uniqueLocalId, stmt.name);
        assert(infoPtr !is null && infoPtr.isStaticArray, "Expected static array local: " ~ stmt.name);
        auto info = *infoPtr;
        
        // Explicitly zero-initialize (shadow stack may have stale data from prior calls)
        if (!stmt.initializer) {
            auto totalBytes = info.elementCount * info.elementSize;
            for (uint offset = 0; offset < totalBytes; offset += 4) {
                out_ ~= Op.local_get;
                leb128u(out_, fpLocal);
                out_ ~= Op.i32_const;
                leb128s(out_, info.frameOffset + offset);
                out_ ~= Op.i32_add;
                out_ ~= Op.i32_const;
                leb128s(out_, 0);
                out_ ~= Op.i32_store;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
            }
            return;
        }
        
        // Array literal initializer: [1, 2, 3, 4]
        if (auto arrayLit = cast(ArrayLiteralExpression)stmt.initializer) {
            uint elemCount = cast(uint)arrayLit.elements.length;
            
            // Store each element at FP + frameOffset + i * elemSize
            for (uint i = 0; i < elemCount && i < info.elementCount; i++) {
                // Address: FP + frameOffset + i * elemSize
                out_ ~= Op.local_get;
                leb128u(out_, fpLocal);
                out_ ~= Op.i32_const;
                leb128s(out_, info.frameOffset + i * info.elementSize);
                out_ ~= Op.i32_add;
                
                // Value
                emitExpression(out_, arrayLit.elements[i]);
                
                // Store
                out_ ~= Op.i32_store;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
            }
            return;
        }
        
        // Function call returning static array: int[3] arr = makeArray(...)
        if (auto callExpr = cast(CallExpression)stmt.initializer) {
            if (auto ident = cast(IdentifierExpression)callExpr.function_) {
                emitStructReturnCall(out_, ident.name, callExpr.arguments, info.frameOffset);
                return;
            }
        }

        throw new EmitError("Unsupported static array initializer",
                           stmt.initializer ? stmt.initializer.toString() : "none");
    }
    
    //==========================================================================
    // Expression Emission
    //==========================================================================
    
    void emitExpression(ref Appender!(ubyte[]) out_, Expression expr) {
        if (auto literal = cast(LiteralExpression)expr) {
            emitLiteral(out_, literal);
        } else if (auto ident = cast(IdentifierExpression)expr) {
            emitIdentifier(out_, ident);
        } else if (auto binary = cast(BinaryExpression)expr) {
            emitBinary(out_, binary);
        } else if (auto unary = cast(UnaryExpression)expr) {
            emitUnary(out_, unary);
        } else if (auto call = cast(CallExpression)expr) {
            emitCall(out_, call);
        } else if (auto assign = cast(AssignmentExpression)expr) {
            emitAssignment(out_, assign);
        } else if (auto member = cast(MemberExpression)expr) {
            emitMember(out_, member);
        } else if (auto castExpr = cast(CastExpression)expr) {
            emitCast(out_, castExpr);
        } else if (auto indexExpr = cast(IndexExpression)expr) {
            emitIndex(out_, indexExpr);
        } else if (auto sliceExpr = cast(SliceExpression)expr) {
            emitSliceExpressionToTemp(out_, sliceExpr);
        } else if (auto traits = cast(TraitsExpression)expr) {
            traits.evaluate();
            out_ ~= Op.i32_const;
            leb128s(out_, traits.boolResult ? 1 : 0);
        } else if (auto isExpr = cast(IsExpression)expr) {
            out_ ~= Op.i32_const;
            leb128s(out_, isExpr.boolResult ? 1 : 0);
        } else if (auto tmplInst = cast(TemplateInstantiationExpression)expr) {
            emitTemplateCall(out_, tmplInst);
        } else {
            throw new EmitError("Unsupported expression type", expr.toString());
        }
    }
    
    void emitIndex(ref Appender!(ubyte[]) out_, IndexExpression expr) {
        // Check if this uses the intrinsic opIndex path
        if (expr.usesOpIndex && expr.opIndexMethod && expr.opIndexMethod.isIntrinsic) {
            emitIntrinsicOpIndex(out_, expr);
            return;
        }
        
        // Non-intrinsic opIndex would emit a method call here
        // (not yet implemented - would call user-defined opIndex)
        
        throw new EmitError("Non-intrinsic indexing not yet supported");
    }
    
    /**
     * Emit intrinsic opIndex for arrays - direct memory access
     */
    void emitIntrinsicOpIndex(ref Appender!(ubyte[]) out_, IndexExpression expr) {
        // Handle member expression as array source (e.g., s.data[i])
        if (auto memberExpr = cast(MemberExpression)expr.array) {
            // emitMember leaves slice address on stack for slice fields
            auto memberType = getMemberExpressionType(memberExpr);
            if (auto arrType = cast(ArrayType)memberType) {
                if (!arrType.isStaticArray) {
                    // Emit address of the slice struct
                    emitMember(out_, memberExpr);
                    // Load ptr from slice struct (offset 0)
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    // Add index * elemSize
                    uint elemSize = wasmElementSize(arrType.elementType);
                    emitExpression(out_, expr.index);
                    out_ ~= Op.i32_const;
                    leb128s(out_, elemSize);
                    out_ ~= Op.i32_mul;
                    out_ ~= Op.i32_add;
                    // Load value for scalar elements
                    bool isFloat = isF64ElementType(arrType.elementType);
                    if (elemSize <= 4 || isFloat)
                        emitLoadForSize(out_, elemSize, isFloat);
                    return;
                }
            }
            throw new EmitError("Cannot index member expression of non-slice type", memberExpr.toString());
        }

        // Get the array identifier
        auto arrayIdent = cast(IdentifierExpression)expr.array;
        if (!arrayIdent) {
            throw new EmitError("Complex array indexing not yet supported");
        }
        
        // Unified variable lookup
        if (auto info = resolveVar(arrayIdent.resolvedLocalId, arrayIdent.name)) {
            if (info.isStaticArray) {
                // Static array: base address + index * elemSize
                emitVarAddress(out_, info);
                emitExpression(out_, expr.index);
                out_ ~= Op.i32_const;
                leb128s(out_, info.elementSize);
                out_ ~= Op.i32_mul;
                out_ ~= Op.i32_add;
                // Aggregate elements: leave address on stack (like struct variables)
                {
                    bool isFloat = isF64ElementType(info.elementType);
                    if (info.elementSize <= 4 || isFloat)
                        emitLoadForSize(out_, info.elementSize, isFloat);
                }
                return;
            } else if (info.isSlice) {
                // Load ptr from slice struct (offset 0), then add index * elemSize
                emitVarAddress(out_, info);
                out_ ~= Op.i32_load;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
                emitExpression(out_, expr.index);
                out_ ~= Op.i32_const;
                leb128s(out_, info.elementSize);
                out_ ~= Op.i32_mul;
                out_ ~= Op.i32_add;
                // Aggregate elements: leave address on stack (like struct variables)
                {
                    bool isFloat = isF64ElementType(info.elementType);
                    if (info.elementSize <= 4 || isFloat)
                        emitLoadForSize(out_, info.elementSize, isFloat);
                }
                return;
            } else {
                assert(0, "Cannot index " ~ arrayIdent.name ~ " (not an array type)");
            }
        }

        // Implicit field access in method: fieldName[i] where field is a slice
        if (auto thisInfo = resolveVar(THIS_LOCAL_ID, "this")) {
            AggregateDecl parent = func.structParent ? cast(AggregateDecl)func.structParent
                                                     : cast(AggregateDecl)func.classParent;
            if (parent) {
                auto field = parent.getField(arrayIdent.name);
                if (field) {
                    if (auto arrType = cast(ArrayType)field.type) {
                        if (!arrType.isStaticArray) {
                            uint elemSize = wasmElementSize(arrType.elementType);
                            // Load ptr from this_ptr + field.offset
                            out_ ~= Op.local_get;
                            leb128u(out_, thisInfo.wasmLocalIdx);
                            if (field.offset > 0) {
                                out_ ~= Op.i32_const;
                                leb128s(out_, cast(int)field.offset);
                                out_ ~= Op.i32_add;
                            }
                            out_ ~= Op.i32_load;  // load slice.ptr
                            out_ ~= cast(ubyte)0x02;
                            leb128u(out_, 0);
                            // Add index * elemSize
                            emitExpression(out_, expr.index);
                            out_ ~= Op.i32_const;
                            leb128s(out_, elemSize);
                            out_ ~= Op.i32_mul;
                            out_ ~= Op.i32_add;
                            // Load value for scalar elements
                            bool isFloat = isF64ElementType(arrType.elementType);
                            if (elemSize <= 4 || isFloat)
                                emitLoadForSize(out_, elemSize, isFloat);
                            return;
                        }
                    }
                }
            }
        }

        // Check if it's a manifest constant array (import(), etc.)
        auto symbol = emitter.symbolTable.lookupSymbol(arrayIdent.name);
        if (symbol && symbol.kind == SymbolKind.Variable && symbol.isConstant) {
            if (auto manifest = cast(ManifestConstantDecl)symbol.declaration) {
                if (manifest.ctfeComplete && (manifest.isArrayType || manifest.isNestedArrayType)) {
                    uint structAddr = manifest.isNestedArrayType
                        ? emitter.registerManifestNestedArray(manifest)
                        : emitter.registerManifestArray(manifest);

                    // Determine element size based on inferred type
                    uint elemSize = manifest.isNestedArrayType
                        ? cast(uint)sliceLayout.totalSize
                        : (manifest.ctfeElementSize > 0 ? manifest.ctfeElementSize : 4);
                    
                    // Load ptr from struct (offset 0)
                    out_ ~= Op.i32_const;
                    leb128s(out_, structAddr);
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    
                    // Calculate address: ptr + index * elemSize
                    emitExpression(out_, expr.index);
                    out_ ~= Op.i32_const;
                    leb128s(out_, elemSize);
                    out_ ~= Op.i32_mul;
                    out_ ~= Op.i32_add;
                    
                    // Load the element (use appropriate size)
                    if (elemSize > 4) {
                        // Aggregate element — leave address on stack
                    } else if (elemSize == 1) {
                        out_ ~= Op.i32_load8_u;  // ubyte
                        out_ ~= cast(ubyte)0x00;
                        leb128u(out_, 0);
                    } else {
                        out_ ~= Op.i32_load;
                        out_ ~= cast(ubyte)0x02;
                        leb128u(out_, 0);
                    }
                    return;
                }
            }
        }
        
        throw new EmitError("Unsupported array indexing on " ~ arrayIdent.name);
    }
    
    /**
     * Emit index assignment for arrays - arr[i] = value
     */
    void emitIndexAssignment(ref Appender!(ubyte[]) out_, IndexExpression indexExpr, Expression value) {
        // Handle member expression as array source (e.g., s.data[i] = value)
        if (auto memberExpr = cast(MemberExpression)indexExpr.array) {
            auto memberType = getMemberExpressionType(memberExpr);
            if (auto arrType = cast(ArrayType)memberType) {
                if (!arrType.isStaticArray) {
                    uint elemSize = wasmElementSize(arrType.elementType);
                    // Emit address of slice struct, load ptr
                    emitMember(out_, memberExpr);
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    // Add index * elemSize
                    emitExpression(out_, indexExpr.index);
                    out_ ~= Op.i32_const;
                    leb128s(out_, elemSize);
                    out_ ~= Op.i32_mul;
                    out_ ~= Op.i32_add;
                    // Store value
                    emitExpression(out_, value);
                    emitStoreForSize(out_, elemSize);
                    emitExpression(out_, value);
                    return;
                }
            }
            throw new EmitError("Cannot index-assign member expression of non-slice type");
        }

        // Get the array identifier
        auto arrayIdent = cast(IdentifierExpression)indexExpr.array;
        if (!arrayIdent) {
            throw new EmitError("Complex array index assignment not yet supported");
        }

        // Check if it's a local on the shadow stack
        // Unified variable lookup
        if (auto info = resolveVar(arrayIdent.resolvedLocalId, arrayIdent.name)) {
            if (info.isStaticArray || info.isSlice) {
                // Compute destination address
                if (info.isStaticArray) {
                    emitVarAddress(out_, info);
                } else {
                    // Slice: load ptr field
                    emitVarAddress(out_, info);
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                }
                emitExpression(out_, indexExpr.index);
                out_ ~= Op.i32_const;
                leb128s(out_, info.elementSize);
                out_ ~= Op.i32_mul;
                out_ ~= Op.i32_add;

                if (info.elementSize > 4) {
                    // Aggregate element: copy elementSize bytes from src to dst
                    out_ ~= Op.local_set;
                    leb128u(out_, tempLocalA);  // save dst addr
                    emitExpression(out_, value);  // src addr (aggregate convention)
                    out_ ~= Op.local_set;
                    leb128u(out_, tempLocalB);  // save src addr
                    // Copy 4 bytes at a time
                    for (uint offset = 0; offset < info.elementSize; offset += 4) {
                        out_ ~= Op.local_get;
                        leb128u(out_, tempLocalA);
                        if (offset > 0) {
                            out_ ~= Op.i32_const;
                            leb128s(out_, offset);
                            out_ ~= Op.i32_add;
                        }
                        out_ ~= Op.local_get;
                        leb128u(out_, tempLocalB);
                        if (offset > 0) {
                            out_ ~= Op.i32_const;
                            leb128s(out_, offset);
                            out_ ~= Op.i32_add;
                        }
                        out_ ~= Op.i32_load;
                        out_ ~= cast(ubyte)0x02;
                        leb128u(out_, 0);
                        out_ ~= Op.i32_store;
                        out_ ~= cast(ubyte)0x02;
                        leb128u(out_, 0);
                    }
                    // Expression value: push dst addr
                    out_ ~= Op.local_get;
                    leb128u(out_, tempLocalA);
                } else {
                    // Scalar element: simple store
                    emitExpression(out_, value);
                    emitStoreForSize(out_, info.elementSize);
                    emitExpression(out_, value);
                }
                return;
            } else {
                assert(0, "Cannot index-assign " ~ arrayIdent.name ~ " (not an array type)");
            }
        }

        // Implicit field access in method: fieldName[i] = value
        if (auto thisInfo = resolveVar(THIS_LOCAL_ID, "this")) {
            AggregateDecl parent = func.structParent ? cast(AggregateDecl)func.structParent
                                                     : cast(AggregateDecl)func.classParent;
            if (parent) {
                auto field = parent.getField(arrayIdent.name);
                if (field) {
                    if (auto arrType = cast(ArrayType)field.type) {
                        if (!arrType.isStaticArray) {
                            uint elemSize = wasmElementSize(arrType.elementType);
                            // Load ptr from this_ptr + field.offset
                            out_ ~= Op.local_get;
                            leb128u(out_, thisInfo.wasmLocalIdx);
                            if (field.offset > 0) {
                                out_ ~= Op.i32_const;
                                leb128s(out_, cast(int)field.offset);
                                out_ ~= Op.i32_add;
                            }
                            out_ ~= Op.i32_load;  // load slice.ptr
                            out_ ~= cast(ubyte)0x02;
                            leb128u(out_, 0);
                            // Add index * elemSize
                            emitExpression(out_, indexExpr.index);
                            out_ ~= Op.i32_const;
                            leb128s(out_, elemSize);
                            out_ ~= Op.i32_mul;
                            out_ ~= Op.i32_add;
                            // Store value
                            emitExpression(out_, value);
                            emitStoreForSize(out_, elemSize);
                            emitExpression(out_, value);
                            return;
                        }
                    }
                }
            }
        }

        throw new EmitError("Unsupported array index assignment on " ~ arrayIdent.name);
    }
    
    /**
     * Emit a built-in method call on a slice (reserve, etc.)
     */
    void emitSliceBuiltinMethod(ref Appender!(ubyte[]) out_, string sliceName,
                                 VarInfo* sliceInfo, string methodName, Expression[] args) {
        if (methodName == "reserve") {
            emitSliceReserve(out_, sliceName, sliceInfo, args);
            return;
        }
        
        throw new EmitError("Unknown slice method: " ~ methodName);
    }
    
    /**
     * Emit arr.reserve(newCapacity)
     * 
     * If newCapacity > current capacity:
     *   1. Allocate new buffer via __alloc
     *   2. Copy existing elements
     *   3. Update slice ptr and capacity
     */
    void emitSliceReserve(ref Appender!(ubyte[]) out_, string sliceName,
                          VarInfo* sliceInfo, Expression[] args) {
        if (args.length != 1) {
            throw new EmitError("reserve() requires exactly 1 argument");
        }
        
        // We need several locals for this operation:
        // - newCapacity (from args[0])
        // - oldCapacity (from slice struct)
        // - newBuffer (from __alloc)
        // - copyIdx (loop counter)
        //
        // For simplicity, we'll use the stack and avoid extra locals.
        // 
        // Algorithm:
        // if (newCapacity > slice.capacity) {
        //     newBuffer = __alloc(newCapacity * 4);
        //     for (i = 0; i < slice.length; i++) {
        //         newBuffer[i] = slice.ptr[i];
        //     }
        //     slice.ptr = newBuffer;
        //     slice.capacity = newCapacity;
        // }
        
        // Slice struct layout: ptr @ 0, length @ 4, capacity @ 8
        int sliceAddr = sliceInfo.frameOffset;
        
        // First, evaluate newCapacity and compare with current capacity
        // Stack: [newCapacity]
        emitExpression(out_, args[0]);
        
        // Load current capacity
        // Stack: [newCapacity, oldCapacity]
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + sliceLayout.capacityOffset);  // capacity offset
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        // if (newCapacity > oldCapacity)
        // Stack: [newCapacity > oldCapacity]
        out_ ~= Op.i32_gt_u;
        
        // if block
        out_ ~= Op.if_;
        out_ ~= cast(ubyte)0x40;  // void block type
        
        // --- Inside the if block ---
        
        // Allocate new buffer: __arena_alloc(arena, newCapacity * 4)
        emitArenaPointer(out_);
        // Re-evaluate newCapacity (we consumed it in comparison)
        emitExpression(out_, args[0]);
        out_ ~= Op.i32_const;
        leb128s(out_, 4);  // sizeof(int)
        out_ ~= Op.i32_mul;

        // Call __arena_alloc
        uint allocIdx = emitter.getFuncIndex("__arena_alloc");
        out_ ~= Op.call;
        leb128u(out_, allocIdx);
        // Stack: [newBuffer]

        // Store newBuffer in a temp location (use SP - 4)
        // Save return value to temp local first (i32.store needs [addr, val] order)
        out_ ~= Op.local_set;
        leb128u(out_, tempLocalA);
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        out_ ~= Op.i32_sub;
        out_ ~= Op.local_get;
        leb128u(out_, tempLocalA);
        // Stack: [SP-4, newBuffer]
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        // Copy loop: for i = 0 to length-1, copy element
        // We'll use a simple loop with block/loop/br_if
        
        // Initialize loop counter at SP-8
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 8);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_const;
        leb128s(out_, 0);  // i = 0
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        // block $break
        out_ ~= Op.block;
        out_ ~= cast(ubyte)0x40;  // void
        
        // loop $continue
        out_ ~= Op.loop;
        out_ ~= cast(ubyte)0x40;  // void
        
        // Check: if (i >= length) break
        // Load i
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 8);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        // Load length
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + sliceLayout.lengthOffset);  // length offset
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        // if i >= length, break
        out_ ~= Op.i32_ge_u;
        out_ ~= Op.br_if;
        leb128u(out_, 1);  // break to outer block
        
        // Copy element: newBuffer[i] = oldPtr[i]
        // Dest address: newBuffer + i * 4
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;  // newBuffer
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 8);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;  // i
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;  // newBuffer + i*4
        
        // Load from old ptr[i]
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr);  // ptr offset = 0
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;  // oldPtr
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 8);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;  // i
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;  // oldPtr + i*4
        
        out_ ~= Op.i32_load;  // load oldPtr[i]
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        // Store to newBuffer[i]
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        // Increment i
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 8);
        out_ ~= Op.i32_sub;
        // Load i, add 1, store back
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 8);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_const;
        leb128s(out_, 1);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        // Continue loop
        out_ ~= Op.br;
        leb128u(out_, 0);  // back to loop
        
        out_ ~= Op.end;  // end loop
        out_ ~= Op.end;  // end block
        
        // Update slice.ptr = newBuffer
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr);  // ptr offset
        out_ ~= Op.i32_add;
        
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;  // newBuffer
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        // Update slice.capacity = newCapacity
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + sliceLayout.capacityOffset);  // capacity offset
        out_ ~= Op.i32_add;
        
        emitExpression(out_, args[0]);  // newCapacity
        
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        out_ ~= Op.end;  // end if
        
        // reserve() returns void, so no value on stack
    }
    
    /**
     * Emit arr ~= value (slice append)
     * 
     * If length >= capacity, grow to capacity * 2 (min 4)
     * Store value at ptr[length]
     * Increment length
     */
    void emitSliceAppend(ref Appender!(ubyte[]) out_, string sliceName,
                         VarInfo* sliceInfo, Expression value) {
        int sliceAddr = sliceInfo.frameOffset;
        bool isFloat = isF64ElementType(sliceInfo.elementType);
        uint elementSize = sliceInfo.elementSize;
        bool isAggregate = (elementSize > 4 && !isFloat);
        // SP scratch layout: value takes valSize bytes, then 3 i32 temporaries
        int valSize = isAggregate ? cast(int)elementSize : (isFloat ? 8 : 4);
        int capOff = valSize + 4;   // newCapacity offset from SP
        int bufOff = valSize + 8;   // newBuffer offset from SP
        int ctrOff = valSize + 12;  // loop counter offset from SP

        // Store value at SP scratch area (we need it later)
        if (isAggregate) {
            // Expression pushes an address to the element data — copy elementSize bytes word by word
            emitExpression(out_, value);
            out_ ~= Op.local_set;
            leb128u(out_, tempLocalA);
            for (uint w = 0; w < elementSize; w += 4) {
                // dest = SP - valSize + w
                out_ ~= Op.global_get;
                leb128u(out_, emitter.spGlobal);
                out_ ~= Op.i32_const;
                leb128s(out_, valSize - w);
                out_ ~= Op.i32_sub;
                // src = tempLocalA + w
                out_ ~= Op.local_get;
                leb128u(out_, tempLocalA);
                if (w > 0) {
                    out_ ~= Op.i32_const;
                    leb128s(out_, w);
                    out_ ~= Op.i32_add;
                }
                out_ ~= Op.i32_load;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
                // store
                out_ ~= Op.i32_store;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
            }
        } else {
            out_ ~= Op.global_get;
            leb128u(out_, emitter.spGlobal);
            out_ ~= Op.i32_const;
            leb128s(out_, valSize);
            out_ ~= Op.i32_sub;
            emitExpression(out_, value);
            if (isFloat) {
                out_ ~= Op.f64_store;
                out_ ~= cast(ubyte)0x03;  // alignment log2(8)
                leb128u(out_, 0);
            } else {
                out_ ~= Op.i32_store;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
            }
        }

        // Check if length >= capacity
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + sliceLayout.lengthOffset);  // length
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);

        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + sliceLayout.capacityOffset);  // capacity
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);

        out_ ~= Op.i32_ge_u;  // length >= capacity

        out_ ~= Op.if_;
        out_ ~= cast(ubyte)0x40;

        // Need to grow: newCapacity = max(capacity * 2, 4)
        // Store newCapacity at SP-capOff
        // First push the destination address
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, capOff);
        out_ ~= Op.i32_sub;

        // Calculate capacity * 2
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + sliceLayout.capacityOffset);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_const;
        leb128s(out_, 2);
        out_ ~= Op.i32_mul;

        // Compare with 4, take max
        out_ ~= Op.i32_const;
        leb128s(out_, 4);

        // if (capacity*2 < 4) use 4 else use capacity*2
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + sliceLayout.capacityOffset);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_const;
        leb128s(out_, 2);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        emitUnsignedMaxSelect(out_);  // max(capacity*2, 4)

        // Now stack has [SP-capOff, newCapacity], store
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);

        // Allocate new buffer via arena
        emitArenaPointer(out_);
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, capOff);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceInfo.elementSize);
        out_ ~= Op.i32_mul;
        uint allocIdx = emitter.getFuncIndex("__arena_alloc");
        out_ ~= Op.call;
        leb128u(out_, allocIdx);

        // Store newBuffer at SP-bufOff
        // Save return value to temp local first (i32.store needs [addr, val] order)
        out_ ~= Op.local_set;
        leb128u(out_, tempLocalA);
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, bufOff);
        out_ ~= Op.i32_sub;
        out_ ~= Op.local_get;
        leb128u(out_, tempLocalA);
        // Stack: [SP-bufOff, newBuffer]
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);

        // Copy loop: i = 0
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, ctrOff);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_const;
        leb128s(out_, 0);
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);

        out_ ~= Op.block;
        out_ ~= cast(ubyte)0x40;
        out_ ~= Op.loop;
        out_ ~= cast(ubyte)0x40;

        // if i >= length break
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, ctrOff);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + sliceLayout.lengthOffset);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_ge_u;
        out_ ~= Op.br_if;
        leb128u(out_, 1);

        // newBuffer[i] = oldPtr[i]
        if (isAggregate) {
            // Compute dest address: newBuffer + i * elementSize → tempLocalA
            out_ ~= Op.global_get;
            leb128u(out_, emitter.spGlobal);
            out_ ~= Op.i32_const;
            leb128s(out_, bufOff);
            out_ ~= Op.i32_sub;
            out_ ~= Op.i32_load;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            out_ ~= Op.global_get;
            leb128u(out_, emitter.spGlobal);
            out_ ~= Op.i32_const;
            leb128s(out_, ctrOff);
            out_ ~= Op.i32_sub;
            out_ ~= Op.i32_load;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            out_ ~= Op.i32_const;
            leb128s(out_, elementSize);
            out_ ~= Op.i32_mul;
            out_ ~= Op.i32_add;
            out_ ~= Op.local_set;
            leb128u(out_, tempLocalA);

            // Compute source address: oldPtr + i * elementSize → tempLocalB
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, sliceAddr);
            out_ ~= Op.i32_add;
            out_ ~= Op.i32_load;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            out_ ~= Op.global_get;
            leb128u(out_, emitter.spGlobal);
            out_ ~= Op.i32_const;
            leb128s(out_, ctrOff);
            out_ ~= Op.i32_sub;
            out_ ~= Op.i32_load;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            out_ ~= Op.i32_const;
            leb128s(out_, elementSize);
            out_ ~= Op.i32_mul;
            out_ ~= Op.i32_add;
            out_ ~= Op.local_set;
            leb128u(out_, tempLocalB);

            // Word-by-word copy
            for (uint w = 0; w < elementSize; w += 4) {
                out_ ~= Op.local_get;
                leb128u(out_, tempLocalA);
                if (w > 0) {
                    out_ ~= Op.i32_const;
                    leb128s(out_, w);
                    out_ ~= Op.i32_add;
                }
                out_ ~= Op.local_get;
                leb128u(out_, tempLocalB);
                if (w > 0) {
                    out_ ~= Op.i32_const;
                    leb128s(out_, w);
                    out_ ~= Op.i32_add;
                }
                out_ ~= Op.i32_load;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
                out_ ~= Op.i32_store;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
            }
        } else {
            // Scalar copy: dest address on stack, load source, store
            out_ ~= Op.global_get;
            leb128u(out_, emitter.spGlobal);
            out_ ~= Op.i32_const;
            leb128s(out_, bufOff);
            out_ ~= Op.i32_sub;
            out_ ~= Op.i32_load;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            out_ ~= Op.global_get;
            leb128u(out_, emitter.spGlobal);
            out_ ~= Op.i32_const;
            leb128s(out_, ctrOff);
            out_ ~= Op.i32_sub;
            out_ ~= Op.i32_load;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            out_ ~= Op.i32_const;
            leb128s(out_, elementSize);
            out_ ~= Op.i32_mul;
            out_ ~= Op.i32_add;

            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, sliceAddr);
            out_ ~= Op.i32_add;
            out_ ~= Op.i32_load;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            out_ ~= Op.global_get;
            leb128u(out_, emitter.spGlobal);
            out_ ~= Op.i32_const;
            leb128s(out_, ctrOff);
            out_ ~= Op.i32_sub;
            out_ ~= Op.i32_load;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            out_ ~= Op.i32_const;
            leb128s(out_, elementSize);
            out_ ~= Op.i32_mul;
            out_ ~= Op.i32_add;
            emitLoadForSize(out_, elementSize, isFloat);

            emitStoreForSize(out_, elementSize, isFloat);
        }

        // i++
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, ctrOff);
        out_ ~= Op.i32_sub;
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, ctrOff);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_const;
        leb128s(out_, 1);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);

        out_ ~= Op.br;
        leb128u(out_, 0);
        out_ ~= Op.end;
        out_ ~= Op.end;

        // Update ptr
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr);
        out_ ~= Op.i32_add;
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, bufOff);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);

        // Update capacity
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + sliceLayout.capacityOffset);
        out_ ~= Op.i32_add;
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, capOff);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);

        out_ ~= Op.end;  // end if (need grow)

        // Store value at ptr[length]
        if (isAggregate) {
            // Compute dest address: ptr + length * elementSize → tempLocalA
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, sliceAddr);
            out_ ~= Op.i32_add;
            out_ ~= Op.i32_load;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, sliceAddr + sliceLayout.lengthOffset);
            out_ ~= Op.i32_add;
            out_ ~= Op.i32_load;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            out_ ~= Op.i32_const;
            leb128s(out_, elementSize);
            out_ ~= Op.i32_mul;
            out_ ~= Op.i32_add;
            out_ ~= Op.local_set;
            leb128u(out_, tempLocalA);

            // Word-by-word copy from scratch area to destination
            for (uint w = 0; w < elementSize; w += 4) {
                // dest word
                out_ ~= Op.local_get;
                leb128u(out_, tempLocalA);
                if (w > 0) {
                    out_ ~= Op.i32_const;
                    leb128s(out_, w);
                    out_ ~= Op.i32_add;
                }
                // source word from scratch
                out_ ~= Op.global_get;
                leb128u(out_, emitter.spGlobal);
                out_ ~= Op.i32_const;
                leb128s(out_, valSize - w);
                out_ ~= Op.i32_sub;
                out_ ~= Op.i32_load;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
                // store
                out_ ~= Op.i32_store;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
            }
        } else {
            // Scalar: compute dest, load from scratch, store
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, sliceAddr);
            out_ ~= Op.i32_add;
            out_ ~= Op.i32_load;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, sliceAddr + sliceLayout.lengthOffset);
            out_ ~= Op.i32_add;
            out_ ~= Op.i32_load;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            out_ ~= Op.i32_const;
            leb128s(out_, elementSize);
            out_ ~= Op.i32_mul;
            out_ ~= Op.i32_add;

            out_ ~= Op.global_get;
            leb128u(out_, emitter.spGlobal);
            out_ ~= Op.i32_const;
            leb128s(out_, valSize);
            out_ ~= Op.i32_sub;
            if (isFloat) {
                out_ ~= Op.f64_load;
                out_ ~= cast(ubyte)0x03;
                leb128u(out_, 0);
            } else {
                out_ ~= Op.i32_load;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
            }

            emitStoreForSize(out_, elementSize, isFloat);
        }
        
        // Increment length
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + sliceLayout.lengthOffset);
        out_ ~= Op.i32_add;
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + sliceLayout.lengthOffset);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_const;
        leb128s(out_, 1);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        // ~= expression result is the slice itself (return new length for testing)
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + sliceLayout.lengthOffset);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
    }
    
    /**
     * Emit slice append for a struct field slice: structVar.field ~= value.
     * Computes the absolute address of the slice field and delegates to the
     * standard append pattern using tempLocalB as the slice base address.
     *
     * Only handles scalar (int-sized) elements for now.
     */
    void emitSliceFieldAppend(ref Appender!(ubyte[]) out_, VarInfo* structInfo,
                               int fieldOffset, ArrayType arrType, Expression value) {
        uint elementSize = wasmElementSize(arrType.elementType);
        // SP scratch layout: value (4 bytes), capOff, bufOff, ctrOff
        int valSize = 4;
        int capOff = valSize + 4;
        int bufOff = valSize + 8;
        int ctrOff = valSize + 12;

        // Helper: emit the slice field absolute address onto the stack
        void emitFieldAddr() {
            emitVarAddress(out_, structInfo);
            if (fieldOffset > 0) {
                out_ ~= Op.i32_const;
                leb128s(out_, fieldOffset);
                out_ ~= Op.i32_add;
            }
        }

        // Helper: load a 32-bit field from the slice struct at the given sub-offset
        void loadSliceField(uint subOffset) {
            emitFieldAddr();
            if (subOffset > 0) {
                out_ ~= Op.i32_const;
                leb128s(out_, subOffset);
                out_ ~= Op.i32_add;
            }
            out_ ~= Op.i32_load;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
        }

        // Helper: store a 32-bit value to a slice struct sub-field
        // Stack before call: [value]
        void storeSliceField(uint subOffset) {
            out_ ~= Op.local_set;
            leb128u(out_, tempLocalA);  // save value
            emitFieldAddr();
            if (subOffset > 0) {
                out_ ~= Op.i32_const;
                leb128s(out_, subOffset);
                out_ ~= Op.i32_add;
            }
            out_ ~= Op.local_get;
            leb128u(out_, tempLocalA);
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
        }

        // Store value at SP scratch area
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, valSize);
        out_ ~= Op.i32_sub;
        emitExpression(out_, value);
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);

        // Check if length >= capacity
        loadSliceField(sliceLayout.lengthOffset);
        loadSliceField(sliceLayout.capacityOffset);
        out_ ~= Op.i32_ge_u;

        out_ ~= Op.if_;
        out_ ~= cast(ubyte)0x40;

        // newCapacity = max(capacity * 2, 4)
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, capOff);
        out_ ~= Op.i32_sub;

        loadSliceField(sliceLayout.capacityOffset);
        out_ ~= Op.i32_const;
        leb128s(out_, 2);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        loadSliceField(sliceLayout.capacityOffset);
        out_ ~= Op.i32_const;
        leb128s(out_, 2);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        emitUnsignedMaxSelect(out_);
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);

        // Allocate new buffer via arena
        emitArenaPointer(out_);
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, capOff);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_const;
        leb128s(out_, elementSize);
        out_ ~= Op.i32_mul;
        uint allocIdx = emitter.getFuncIndex("__arena_alloc");
        out_ ~= Op.call;
        leb128u(out_, allocIdx);

        // Store newBuffer at SP-bufOff
        out_ ~= Op.local_set;
        leb128u(out_, tempLocalA);
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, bufOff);
        out_ ~= Op.i32_sub;
        out_ ~= Op.local_get;
        leb128u(out_, tempLocalA);
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);

        // Copy loop: i = 0
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, ctrOff);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_const;
        leb128s(out_, 0);
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);

        out_ ~= Op.block;
        out_ ~= cast(ubyte)0x40;
        out_ ~= Op.loop;
        out_ ~= cast(ubyte)0x40;

        // if i >= length break
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, ctrOff);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        loadSliceField(sliceLayout.lengthOffset);
        out_ ~= Op.i32_ge_u;
        out_ ~= Op.br_if;
        leb128u(out_, 1);

        // newBuffer[i] = oldPtr[i] (scalar copy)
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, bufOff);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, ctrOff);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_const;
        leb128s(out_, elementSize);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;

        // Load from old ptr[i]
        loadSliceField(0);  // slice.ptr
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, ctrOff);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_const;
        leb128s(out_, elementSize);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;
        emitLoadForSize(out_, elementSize, false);
        emitStoreForSize(out_, elementSize, false);

        // i++
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, ctrOff);
        out_ ~= Op.i32_sub;
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, ctrOff);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_const;
        leb128s(out_, 1);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);

        out_ ~= Op.br;
        leb128u(out_, 0);
        out_ ~= Op.end;
        out_ ~= Op.end;

        // Update slice.ptr = newBuffer
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, bufOff);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        storeSliceField(0);  // slice.ptr

        // Update slice.capacity = newCapacity
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, capOff);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        storeSliceField(sliceLayout.capacityOffset);

        out_ ~= Op.end;  // end if (need grow)

        // Store value at ptr[length]: dest = ptr + length * elemSize
        loadSliceField(0);  // ptr
        loadSliceField(sliceLayout.lengthOffset);  // length
        out_ ~= Op.i32_const;
        leb128s(out_, elementSize);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;
        // Load value from SP scratch
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, valSize);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        emitStoreForSize(out_, elementSize, false);

        // Increment length
        loadSliceField(sliceLayout.lengthOffset);
        out_ ~= Op.i32_const;
        leb128s(out_, 1);
        out_ ~= Op.i32_add;
        storeSliceField(sliceLayout.lengthOffset);

        // Result: new length
        loadSliceField(sliceLayout.lengthOffset);
    }

    void emitCast(ref Appender!(ubyte[]) out_, CastExpression expr) {
        // Check for class→interface cast (annotated by type checker)
        if (expr.sourceClassDecl && expr.targetInterfaceDecl) {
            // Emit fat pointer: (obj_ptr, itable_ptr)
            emitClassToInterfaceCast(out_, expr);
            return;
        }

        // Check for f64→i32 truncation (e.g., cast(int)(doubleExpr))
        if (auto targetBt = cast(BasicType)expr.targetType) {
            bool targetIsInt = targetBt.kind != BasicType.Kind.Float64 &&
                               targetBt.kind != BasicType.Kind.Float32;
            if (targetIsInt && isF64Expression(expr.expression)) {
                emitExpression(out_, expr.expression);
                out_ ~= Op.i32_trunc_f64_s;
                return;
            }
        }

        // Emit the expression being cast
        emitExpression(out_, expr.expression);
        // For now, most casts are no-ops at WASM level (everything is i32)
    }
    
    /**
     * Emit class→interface cast as fat pointer (obj_ptr, itable_ptr)
     */
    void emitClassToInterfaceCast(ref Appender!(ubyte[]) out_, CastExpression expr) {
        auto srcClass = expr.sourceClassDecl;
        auto targetIface = expr.targetInterfaceDecl;
        
        // Get the source expression - should be a class identifier
        if (auto identExpr = cast(IdentifierExpression)expr.expression) {
            // Emit obj_ptr
            if (auto info = resolveVar(identExpr.resolvedLocalId, identExpr.name)) {
                if (info.isClass) {
                    emitVarAddress(out_, info);
                } else {
                    throw new EmitError("Variable is not a class in cast: " ~ identExpr.name);
                }
            } else {
                throw new EmitError("Unknown class variable in cast: " ~ identExpr.name);
            }
            
            // Emit itable_ptr
            string ifaceName = targetIface.name;
            if (auto itableBase = ifaceName in srcClass.itableBases) {
                out_ ~= Op.i32_const;
                leb128s(out_, cast(int)*itableBase);
            } else {
                throw new EmitError("Class " ~ srcClass.name ~ " has no itable for interface " ~ ifaceName);
            }
        } else {
            throw new EmitError("Class→interface cast requires identifier expression");
        }
    }
    
    void emitMember(ref Appender!(ubyte[]) out_, MemberExpression expr) {
        // Check if this is a Type.sizeof or Type.alignof
        if (auto ident = cast(IdentifierExpression)expr.object) {
            auto symbol = emitter.symbolTable.lookupSymbol(ident.name);
            if (symbol && symbol.kind == SymbolKind.Type) {
                if (expr.memberName == "sizeof") {
                    // Emit the type's size as a constant
                    size_t size = symbol.type.size();
                    out_ ~= Op.i32_const;
                    leb128s(out_, cast(int)size);
                    return;
                } else if (expr.memberName == "alignof") {
                    // Emit the type's alignment as a constant
                    size_t align_ = symbol.type.alignment();
                    out_ ~= Op.i32_const;
                    leb128s(out_, cast(int)align_);
                    return;
                }
            }
            
            // Check if it's a string constant (MSG.length, MSG.ptr)
            if (symbol && symbol.kind == SymbolKind.Variable) {
                if (auto varDecl = cast(VariableDecl)symbol.declaration) {
                    if (cast(ArrayType)varDecl.type) {
                        if (varDecl.initializer) {
                            if (auto lit = cast(LiteralExpression)varDecl.initializer) {
                                if (lit.value.type == typeid(string)) {
                                    string strValue = lit.value.get!string();
                                    uint structAddr = emitter.registerArrayLiteral(strValue);
                                    
                                    if (expr.memberName == "length") {
                                        // Length is at offset 4 in Array struct
                                        out_ ~= Op.i32_const;
                                        leb128s(out_, structAddr + 4);
                                        out_ ~= Op.i32_load;
                                        out_ ~= cast(ubyte)0x02;
                                        leb128u(out_, 0);
                                        return;
                                    } else if (expr.memberName == "ptr") {
                                        out_ ~= Op.i32_const;
                                        leb128s(out_, structAddr);
                                        out_ ~= Op.i32_load;
                                        out_ ~= cast(ubyte)0x02;
                                        leb128u(out_, 0);
                                        return;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            // Check if it's a manifest constant array (import(), array literal, etc.)
            if (symbol && symbol.kind == SymbolKind.Variable && symbol.isConstant) {
                if (auto manifest = cast(ManifestConstantDecl)symbol.declaration) {
                    if (manifest.ctfeComplete && (manifest.isArrayType || manifest.isNestedArrayType)) {
                        // Register the array data and get struct address
                        uint structAddr = manifest.isNestedArrayType
                            ? emitter.registerManifestNestedArray(manifest)
                            : emitter.registerManifestArray(manifest);
                        
                        if (expr.memberName == "length") {
                            // Length is at offset 4 in Array struct
                            out_ ~= Op.i32_const;
                            leb128s(out_, structAddr + 4);
                            out_ ~= Op.i32_load;
                            out_ ~= cast(ubyte)0x02;
                            leb128u(out_, 0);
                            return;
                        } else if (expr.memberName == "ptr") {
                            // Ptr is at offset 0
                            out_ ~= Op.i32_const;
                            leb128s(out_, structAddr);
                            out_ ~= Op.i32_load;
                            out_ ~= cast(ubyte)0x02;
                            leb128u(out_, 0);
                            return;
                        } else if (expr.memberName == "capacity") {
                            // Capacity is at offset 8
                            out_ ~= Op.i32_const;
                            leb128s(out_, structAddr + 8);
                            out_ ~= Op.i32_load;
                            out_ ~= cast(ubyte)0x02;
                            leb128u(out_, 0);
                            return;
                        }
                    }
                }
            }
            
            // Check if it's a variable with struct type (e.g., P.x where P is a global struct)
            if (symbol && symbol.kind == SymbolKind.Variable) {
                if (auto varDecl = cast(VariableDecl)symbol.declaration) {
                    if (varDecl.ctfeComplete) {
                        // Global struct variable - load field from data section
                        if (auto structDecl = varDecl.type.asStruct()) {
                                auto field = structDecl.getField(expr.memberName);
                                if (field) {
                                    // Load i32 from data section at struct address + field offset
                                    uint address = varDecl.ctfeStructAddress + cast(uint)field.offset;
                                    out_ ~= Op.i32_const;
                                    leb128s(out_, address);
                                    out_ ~= Op.i32_load;
                                    out_ ~= cast(ubyte)0x02;  // alignment (log2 of 4 bytes)
                                    leb128u(out_, 0);  // offset
                                    return;
                                }
                        }
                    }
                }
            }
            
            // Check locals/params (struct, class, slice)
            if (auto info = resolveVar(ident.resolvedLocalId, ident.name)) {
                if (info.isStruct || info.isClass) {
                    auto aggr = info.isStruct ? cast(AggregateDecl)info.structDecl
                                              : cast(AggregateDecl)info.classDecl;
                    auto field = aggr.getField(expr.memberName);
                    if (field) {
                        // Slice field: emit address (struct_base + field.offset)
                        // Consumed by chained .length/.ptr/[i]/~= on the outer expression
                        if (auto arrType = cast(ArrayType)field.type) {
                            if (!arrType.isStaticArray) {
                                emitVarAddress(out_, info);
                                if (field.offset > 0) {
                                    out_ ~= Op.i32_const;
                                    leb128s(out_, cast(int)field.offset);
                                    out_ ~= Op.i32_add;
                                }
                                return;  // address of slice struct on stack
                            }
                        }
                        emitVarAddress(out_, info);
                        if (field.offset > 0) {
                            out_ ~= Op.i32_const;
                            leb128s(out_, cast(int)field.offset);
                            out_ ~= Op.i32_add;
                        }
                        out_ ~= Op.i32_load;
                        out_ ~= cast(ubyte)0x02;
                        leb128u(out_, 0);
                        return;
                    }
                } else if (info.isSlice) {
                    int fieldOffset;
                    if (expr.memberName == "ptr") fieldOffset = 0;
                    else if (expr.memberName == "length") fieldOffset = cast(int)sliceLayout.lengthOffset;
                    else if (expr.memberName == "capacity") fieldOffset = cast(int)sliceLayout.capacityOffset;
                    else throw new EmitError("Slice has no field '" ~ expr.memberName ~ "'");

                    emitVarAddress(out_, info);
                    if (fieldOffset > 0) {
                        out_ ~= Op.i32_const;
                        leb128s(out_, fieldOffset);
                        out_ ~= Op.i32_add;
                    }
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    return;
                }
            }

            // Implicit field access in method: field.length, field.ptr etc.
            if (auto thisInfo = resolveVar(THIS_LOCAL_ID, "this")) {
                AggregateDecl parent = func.structParent ? cast(AggregateDecl)func.structParent
                                                         : cast(AggregateDecl)func.classParent;
                if (parent) {
                    auto field = parent.getField(ident.name);
                    if (field) {
                        if (auto arrType = cast(ArrayType)field.type) {
                            if (!arrType.isStaticArray) {
                                // Slice field: handle .length/.ptr/.capacity
                                uint subOffset;
                                if (expr.memberName == "length") subOffset = sliceLayout.lengthOffset;
                                else if (expr.memberName == "ptr") subOffset = 0;
                                else if (expr.memberName == "capacity") subOffset = sliceLayout.capacityOffset;
                                else throw new EmitError("Slice field has no member '" ~ expr.memberName ~ "'");
                                out_ ~= Op.local_get;
                                leb128u(out_, thisInfo.wasmLocalIdx);
                                out_ ~= Op.i32_const;
                                leb128s(out_, cast(int)(field.offset + subOffset));
                                out_ ~= Op.i32_add;
                                out_ ~= Op.i32_load;
                                out_ ~= cast(ubyte)0x02;
                                leb128u(out_, 0);
                                return;
                            }
                        }
                    }
                }
            }
        }
        // Handle member access through index expression (points[i].x)
        if (auto indexExpr = cast(IndexExpression)expr.object) {
            // emitIntrinsicOpIndex leaves element address on stack for aggregates
            emitIntrinsicOpIndex(out_, indexExpr);
            auto elemType = getIndexExpressionElementType(indexExpr);
            if (auto structDecl = elemType.asStruct()) {
                auto field = structDecl.getField(expr.memberName);
                if (field) {
                    if (field.offset > 0) {
                        out_ ~= Op.i32_const;
                        leb128s(out_, cast(int)field.offset);
                        out_ ~= Op.i32_add;
                    }
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    return;
                }
            }
            // Slice element — handle .length, .ptr
            if (elemType) {
                if (cast(ArrayType)elemType) {
                    int fieldOffset = -1;
                    if (expr.memberName == "ptr") fieldOffset = 0;
                    else if (expr.memberName == "length") fieldOffset = 4;
                    else if (expr.memberName == "capacity") fieldOffset = 8;
                    if (fieldOffset >= 0) {
                        if (fieldOffset > 0) {
                            out_ ~= Op.i32_const;
                            leb128s(out_, fieldOffset);
                            out_ ~= Op.i32_add;
                        }
                        out_ ~= Op.i32_load;
                        out_ ~= cast(ubyte)0x02;
                        leb128u(out_, 0);
                        return;
                    }
                }
            }
        }

        // Handle chained member access (o.i.a where object is MemberExpression)
        if (auto innerMember = cast(MemberExpression)expr.object) {
            // Get the type of the inner member to find the field
            // Emit address of inner member, then add field offset and load
            emitMemberAddress(out_, innerMember);

            // Now we need to find the field within the type of innerMember
            // Get the struct type of innerMember
            auto innerType = getMemberExpressionType(innerMember);
            if (auto structDecl = innerType.asStruct()) {
                auto field = structDecl.getField(expr.memberName);
                if (field) {
                    // Add field offset and load
                    if (field.offset > 0) {
                        out_ ~= Op.i32_const;
                        leb128s(out_, cast(int)field.offset);
                        out_ ~= Op.i32_add;
                    }
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    return;
                }
            }
            // Inner member is a slice — handle .length/.ptr/.capacity
            if (auto arrType = cast(ArrayType)innerType) {
                if (!arrType.isStaticArray) {
                    // Address of the slice struct is on the stack
                    if (expr.memberName == "length") {
                        out_ ~= Op.i32_const;
                        leb128s(out_, sliceLayout.lengthOffset);
                        out_ ~= Op.i32_add;
                    } else if (expr.memberName == "ptr") {
                        // ptr is at offset 0, no add needed
                    } else if (expr.memberName == "capacity") {
                        out_ ~= Op.i32_const;
                        leb128s(out_, sliceLayout.capacityOffset);
                        out_ ~= Op.i32_add;
                    } else {
                        throw new EmitError("Slice field has no member '" ~ expr.memberName ~ "'");
                    }
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    return;
                }
            }
        }

        throw new EmitError("Member access not yet fully implemented", expr.toString());
    }
    
    /**
     * Emit the ADDRESS of a member expression (for nested access).
     * Leaves address on stack, doesn't load the value.
     */
    void emitMemberAddress(ref Appender!(ubyte[]) out_, MemberExpression expr) {
        if (auto ident = cast(IdentifierExpression)expr.object) {
            // Check struct/class locals and params
            if (auto info = resolveVar(ident.resolvedLocalId, ident.name)) {
                if (info.isStruct || info.isClass) {
                    auto aggr = info.isStruct ? cast(AggregateDecl)info.structDecl
                                              : cast(AggregateDecl)info.classDecl;
                    auto field = aggr.getField(expr.memberName);
                    if (field) {
                        emitVarAddress(out_, info);
                        if (field.offset > 0) {
                            out_ ~= Op.i32_const;
                            leb128s(out_, cast(int)field.offset);
                            out_ ~= Op.i32_add;
                        }
                        return;
                    }
                }
            }
        }
        // Handle index expression as object (points[i].x in address context)
        if (auto indexExpr = cast(IndexExpression)expr.object) {
            emitIntrinsicOpIndex(out_, indexExpr);
            auto elemType = getIndexExpressionElementType(indexExpr);
            if (auto structDecl = elemType.asStruct()) {
                auto field = structDecl.getField(expr.memberName);
                if (field && field.offset > 0) {
                    out_ ~= Op.i32_const;
                    leb128s(out_, cast(int)field.offset);
                    out_ ~= Op.i32_add;
                }
                return;
            }
        }
        // Recursive case: object is also a MemberExpression
        if (auto innerMember = cast(MemberExpression)expr.object) {
            emitMemberAddress(out_, innerMember);
            auto innerType = getMemberExpressionType(innerMember);
            if (auto structDecl = innerType.asStruct()) {
                auto field = structDecl.getField(expr.memberName);
                if (field && field.offset > 0) {
                    out_ ~= Op.i32_const;
                    leb128s(out_, cast(int)field.offset);
                    out_ ~= Op.i32_add;
                }
                return;
            }
        }
        throw new EmitError("Cannot compute address of member", expr.toString());
    }
    
    /**
     * Get the element type of an index expression (e.g., Point for Point[3]).
     * Returns null if the array variable can't be found.
     */
    Type getIndexExpressionElementType(IndexExpression expr) {
        auto arrayIdent = cast(IdentifierExpression)expr.array;
        if (!arrayIdent) return null;
        if (auto info = resolveVar(arrayIdent.resolvedLocalId, arrayIdent.name)) {
            return info.elementType;
        }
        return null;
    }

    /**
     * Get the type of a member expression (for determining nested field offsets).
     */
    Type getMemberExpressionType(MemberExpression expr) {
        Type objType;

        if (auto ident = cast(IdentifierExpression)expr.object) {
            // Check locals and params for struct type
            StructDecl sd;
            if (auto info = resolveVar(ident.resolvedLocalId, ident.name)) {
                if (info.isStruct) sd = info.structDecl;
            }
            if (sd) {
                objType = new UserType(SourceLocation(), sd.name);
                (cast(UserType)objType).declaration = sd;
            }
        } else if (auto innerMember = cast(MemberExpression)expr.object) {
            objType = getMemberExpressionType(innerMember);
        } else if (auto indexExpr = cast(IndexExpression)expr.object) {
            // Array element type (e.g., points[i] → Point)
            objType = getIndexExpressionElementType(indexExpr);
        }

        if (auto structDecl = objType.asStruct()) {
            auto field = structDecl.getField(expr.memberName);
            if (field) {
                return field.type;
            }
        }

        return null;
    }
    
    /// Emit WASM `select` as unsigned-max: max(val1, val2).
    /// Stack before: [val1, val2, val1, val2]
    ///   (first pair = select candidates, second pair = comparison operands)
    /// Stack after: [max(val1, val2)]
    static void emitUnsignedMaxSelect(ref Appender!(ubyte[]) out_) {
        out_ ~= Op.i32_ge_u;   // [val1, val2, (val1 >= val2)]
        out_ ~= Op.select;      // returns val1 if val1 >= val2, else val2
    }

    /// Check if an element type is a 64-bit floating point.
    private static bool isF64ElementType(Type t) {
        if (auto bt = cast(BasicType)t)
            return bt.kind == BasicType.Kind.Float64 || bt.kind == BasicType.Kind.Float32;
        return false;
    }

    /// Check if an expression produces f64 on the WASM stack.
    private bool isF64Expression(Expression expr) {
        if (auto lit = cast(LiteralExpression)expr)
            return lit.value.type == typeid(double);
        if (auto idx = cast(IndexExpression)expr) {
            if (auto ident = cast(IdentifierExpression)idx.array)
                if (auto info = resolveVar(ident.resolvedLocalId, ident.name))
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

    /// Emit a load instruction appropriate for the given element size.
    void emitLoadForSize(ref Appender!(ubyte[]) out_, uint elemSize, bool isFloat = false) {
        if (elemSize == 1) {
            out_ ~= Op.i32_load8_u;
            out_ ~= cast(ubyte)0x00;
            leb128u(out_, 0);
        } else if (elemSize == 8 && isFloat) {
            out_ ~= Op.f64_load;
            out_ ~= cast(ubyte)0x03;  // alignment log2(8)
            leb128u(out_, 0);
        } else {
            out_ ~= Op.i32_load;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
        }
    }

    /// Emit a store instruction appropriate for the given element size.
    void emitStoreForSize(ref Appender!(ubyte[]) out_, uint elemSize, bool isFloat = false) {
        if (elemSize == 1) {
            out_ ~= Op.i32_store8;
            out_ ~= cast(ubyte)0x00;
            leb128u(out_, 0);
        } else if (elemSize == 8 && isFloat) {
            out_ ~= Op.f64_store;
            out_ ~= cast(ubyte)0x03;  // alignment log2(8)
            leb128u(out_, 0);
        } else {
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
        }
    }

    void emitLiteral(ref Appender!(ubyte[]) out_, LiteralExpression expr) {
        if (expr.value.type == typeid(long)) {
            long value = expr.value.get!long();
            // Handle 32-bit values: allow both signed i32 and unsigned u32 range
            // Values like 0xEDB88320 (3988292384) are valid u32 but exceed i32.max
            // Convert to signed i32 via two's complement for WASM encoding
            if (value > uint.max || value < int.min) {
                throw new EmitError(
                    format("Integer literal %d exceeds 32-bit range [%d, %d]", value, int.min, uint.max),
                    "literal emission"
                );
            }
            // If value is in unsigned range but above signed max, convert to signed
            int i32Value = (value > int.max) ? cast(int)(value & 0xFFFFFFFF) : cast(int)value;
            out_ ~= Op.i32_const;
            leb128s(out_, i32Value);
        } else if (expr.value.type == typeid(bool)) {
            out_ ~= Op.i32_const;
            leb128s(out_, expr.value.get!bool() ? 1 : 0);
        } else if (expr.value.type == typeid(char)) {
            out_ ~= Op.i32_const;
            leb128s(out_, cast(int)expr.value.get!char());
        } else if (expr.value.type == typeid(double)) {
            out_ ~= Op.f64_const;
            double val = expr.value.get!double();
            out_ ~= (cast(ubyte*)&val)[0..8];
        } else if (expr.value.type == typeid(string)) {
            // String literal: emit pointer to Array struct
            string s = expr.value.get!string();
            uint structAddr = emitter.registerArrayLiteral(s);
            out_ ~= Op.i32_const;
            leb128s(out_, structAddr);
        } else {
            throw new EmitError("Unsupported literal type");
        }
    }
    
    void emitIdentifier(ref Appender!(ubyte[]) out_, IdentifierExpression expr) {
        // Unified variable resolution: check varsByLocalId/varsByName first
        if (auto info = resolveVar(expr.resolvedLocalId, expr.name)) {
            final switch (info.addrMode) {
                case AddrMode.wasmLocal:
                    out_ ~= Op.local_get;
                    leb128u(out_, info.wasmLocalIdx);
                    return;
                case AddrMode.shadowStack:
                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.frameOffset);
                    out_ ~= Op.i32_add;
                    return;
                case AddrMode.paramPointer:
                    out_ ~= Op.local_get;
                    leb128u(out_, info.wasmLocalIdx);
                    return;
            }
        }

        // Not a local/param — check symbol table for implicit field access, constants, globals
        Symbol symbol = emitter.symbolTable.lookupSymbol(expr.name);

        // In a method, check if it's an implicit field access (field without 'this.')
        if (auto thisInfo = resolveVar(THIS_LOCAL_ID, "this")) {
            AggregateDecl parent = func.structParent ? cast(AggregateDecl)func.structParent
                                                     : cast(AggregateDecl)func.classParent;
            if (parent) {
                auto field = parent.getField(expr.name);
                if (field) {
                    // Slice field: emit address (this_ptr + field.offset) — consumed by .length, [i], ~= etc.
                    if (auto arrType = cast(ArrayType)field.type) {
                        if (!arrType.isStaticArray) {
                            out_ ~= Op.local_get;
                            leb128u(out_, thisInfo.wasmLocalIdx);
                            if (field.offset > 0) {
                                out_ ~= Op.i32_const;
                                leb128s(out_, cast(int)field.offset);
                                out_ ~= Op.i32_add;
                            }
                            return;  // address of slice struct on stack
                        }
                    }
                    out_ ~= Op.local_get;
                    leb128u(out_, thisInfo.wasmLocalIdx);
                    if (field.offset > 0) {
                        out_ ~= Op.i32_const;
                        leb128s(out_, cast(int)field.offset);
                        out_ ~= Op.i32_add;
                    }
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;  // alignment log2(4)
                    leb128u(out_, 0);          // offset
                    return;
                }
            }
        }

        // Check if it's a manifest constant (CTFE-evaluated lazily)
        if (symbol && symbol.isConstant) {
            if (auto manifest = cast(ManifestConstantDecl)symbol.declaration) {
                // Trigger lazy evaluation if needed, then emit
                if (manifest.isStringType) {
                    if (!manifest.ctfeComplete) {
                        emitter.symbolTable.resolveManifestValue(manifest);
                    }
                    uint structAddr = emitter.registerArrayLiteral(manifest.ctfeStringValue);
                    out_ ~= Op.i32_const;
                    leb128s(out_, structAddr);
                } else if (manifest.isFloatType) {
                    if (!manifest.ctfeComplete) {
                        emitter.symbolTable.resolveManifestValue(manifest);
                    }
                    out_ ~= Op.f64_const;
                    double val = manifest.ctfeFloatValue;
                    out_ ~= (cast(ubyte*)&val)[0 .. 8];
                } else {
                    out_ ~= Op.i32_const;
                    leb128s(out_, emitter.symbolTable.resolveManifestValue(manifest));
                }
                return;
            }
        }

        // Check if it's a scalar global variable
        if (symbol) {
            if (auto varDecl = cast(VariableDecl)symbol.declaration) {
                if (varDecl.wasmGlobalIndex != uint.max) {
                    out_ ~= Op.global_get;
                    leb128u(out_, varDecl.wasmGlobalIndex);
                    return;
                }
                // Global exists but wasn't collected — happens during CTFE
                throw new EmitError(
                    "Cannot access module-level variable '" ~ expr.name ~ "' during CTFE",
                    expr.location);
            }
        }

        throw new EmitError("Unknown identifier: " ~ expr.name, expr.location);
    }

    void emitBinary(ref Appender!(ubyte[]) out_, BinaryExpression expr) {
        // Handle string concatenation specially
        if (expr.operator == BinaryExpression.Operator.Concat) {
            emitArrayConcat(out_, expr);
            return;
        }

        // Lowered operators (shifts, struct comparison) — emit the lowered expression
        if (expr.loweredCall) {
            emitExpression(out_, expr.loweredCall);
            return;
        }

        // Short-circuit evaluation for && and ||
        if (expr.operator == BinaryExpression.Operator.LogicalAnd) {
            // a && b  →  if(a) { b != 0 } else { 0 }
            emitExpression(out_, expr.left);
            out_ ~= Op.if_;
            out_ ~= cast(ubyte)BlockType.i32;
            blockDepth++;
            emitExpression(out_, expr.right);
            out_ ~= Op.i32_const;
            leb128s(out_, 0);
            out_ ~= Op.i32_ne;
            out_ ~= Op.else_;
            out_ ~= Op.i32_const;
            leb128s(out_, 0);
            blockDepth--;
            out_ ~= Op.end;
            return;
        }
        if (expr.operator == BinaryExpression.Operator.LogicalOr) {
            // a || b  →  if(a) { 1 } else { b != 0 }
            emitExpression(out_, expr.left);
            out_ ~= Op.if_;
            out_ ~= cast(ubyte)BlockType.i32;
            blockDepth++;
            out_ ~= Op.i32_const;
            leb128s(out_, 1);
            out_ ~= Op.else_;
            emitExpression(out_, expr.right);
            out_ ~= Op.i32_const;
            leb128s(out_, 0);
            out_ ~= Op.i32_ne;
            blockDepth--;
            out_ ~= Op.end;
            return;
        }

        // Emit operands
        emitExpression(out_, expr.left);
        emitExpression(out_, expr.right);

        // Emit operator — dispatch f64 ops when operands are float
        Op op;
        bool isFloat = isF64Expression(expr.left);
        if (isFloat) {
            switch (expr.operator) {
                case BinaryExpression.Operator.Add: op = Op.f64_add; break;
                case BinaryExpression.Operator.Subtract: op = Op.f64_sub; break;
                case BinaryExpression.Operator.Multiply: op = Op.f64_mul; break;
                case BinaryExpression.Operator.Divide: op = Op.f64_div; break;
                case BinaryExpression.Operator.Equal: op = Op.f64_eq; break;
                case BinaryExpression.Operator.NotEqual: op = Op.f64_ne; break;
                case BinaryExpression.Operator.Less: op = Op.f64_lt; break;
                case BinaryExpression.Operator.LessEqual: op = Op.f64_le; break;
                case BinaryExpression.Operator.Greater: op = Op.f64_gt; break;
                case BinaryExpression.Operator.GreaterEqual: op = Op.f64_ge; break;
                default:
                    assert(0, "Float binary operator not supported: " ~ to!string(expr.operator));
            }
        } else final switch (expr.operator) {
            case BinaryExpression.Operator.Add: op = Op.i32_add; break;
            case BinaryExpression.Operator.Subtract: op = Op.i32_sub; break;
            case BinaryExpression.Operator.Multiply: op = Op.i32_mul; break;
            case BinaryExpression.Operator.Divide: op = Op.i32_div_s; break;
            case BinaryExpression.Operator.Modulo: op = Op.i32_rem_s; break;
            case BinaryExpression.Operator.Equal: op = Op.i32_eq; break;
            case BinaryExpression.Operator.NotEqual: op = Op.i32_ne; break;
            case BinaryExpression.Operator.Less: op = Op.i32_lt_s; break;
            case BinaryExpression.Operator.LessEqual: op = Op.i32_le_s; break;
            case BinaryExpression.Operator.Greater: op = Op.i32_gt_s; break;
            case BinaryExpression.Operator.GreaterEqual: op = Op.i32_ge_s; break;
            case BinaryExpression.Operator.LogicalAnd:
                assert(0, "LogicalAnd should be handled by short-circuit above");
            case BinaryExpression.Operator.LogicalOr:
                assert(0, "LogicalOr should be handled by short-circuit above");
            case BinaryExpression.Operator.BitwiseAnd: op = Op.i32_and; break;
            case BinaryExpression.Operator.BitwiseOr: op = Op.i32_or; break;
            case BinaryExpression.Operator.BitwiseXor: op = Op.i32_xor; break;
            case BinaryExpression.Operator.ShiftLeft:
                assert(0, "ShiftLeft should be lowered to opShiftLeft call");
            case BinaryExpression.Operator.ShiftRight:
                assert(0, "ShiftRight should be lowered to opShiftRight call");
            case BinaryExpression.Operator.UnsignedShiftRight:
                assert(0, "UnsignedShiftRight should be lowered to opUnsignedShiftRight call");
            case BinaryExpression.Operator.Concat:
                assert(false, "Concat should be handled above");
        }
        out_ ~= op;
    }
    
    void emitArrayConcat(ref Appender!(ubyte[]) out_, BinaryExpression expr) {
        // Emit left operand (pushes array struct pointer)
        emitExpression(out_, expr.left);
        
        // Emit right operand (pushes array struct pointer)
        emitExpression(out_, expr.right);
        
        // Call __array_concat(s1, s2) -> result_ptr
        out_ ~= Op.call;
        leb128u(out_, emitter.concatFuncIndex);
    }
    
    void emitUnary(ref Appender!(ubyte[]) out_, UnaryExpression expr) {
        final switch (expr.operator) {
            case UnaryExpression.Operator.Plus:
                emitExpression(out_, expr.operand);
                break;
                
            case UnaryExpression.Operator.Minus:
                out_ ~= Op.i32_const;
                leb128s(out_, 0);
                emitExpression(out_, expr.operand);
                out_ ~= Op.i32_sub;
                break;
                
            case UnaryExpression.Operator.LogicalNot:
                emitExpression(out_, expr.operand);
                out_ ~= Op.i32_eqz;
                break;
                
            case UnaryExpression.Operator.BitwiseNot:
                emitExpression(out_, expr.operand);
                out_ ~= Op.i32_const;
                leb128s(out_, -1);
                out_ ~= Op.i32_xor;
                break;
                
            case UnaryExpression.Operator.PreIncrement:
            case UnaryExpression.Operator.PostIncrement:
                emitIncDec(out_, expr, true);
                break;
                
            case UnaryExpression.Operator.PreDecrement:
            case UnaryExpression.Operator.PostDecrement:
                emitIncDec(out_, expr, false);
                break;
                
            case UnaryExpression.Operator.AddressOf:
            case UnaryExpression.Operator.Dereference:
                throw new EmitError("Pointer operations not yet supported");
        }
    }
    
    void emitIncDec(ref Appender!(ubyte[]) out_, UnaryExpression expr, bool inc) {
        auto ident = cast(IdentifierExpression)expr.operand;
        if (!ident) {
            throw new EmitError("Increment/decrement requires identifier");
        }

        // Check unified map first (locals and params)
        if (auto info = resolveVar(ident.resolvedLocalId, ident.name)) {
            if (info.addrMode != AddrMode.wasmLocal)
                throw new EmitError("Increment/decrement requires scalar variable");
            auto idx = info.wasmLocalIdx;

            if (expr.isPostfix) {
                out_ ~= Op.local_get;
                leb128u(out_, idx);
                out_ ~= Op.local_get;
                leb128u(out_, idx);
                out_ ~= Op.i32_const;
                leb128s(out_, 1);
                out_ ~= (inc ? Op.i32_add : Op.i32_sub);
                out_ ~= Op.local_set;
                leb128u(out_, idx);
            } else {
                out_ ~= Op.local_get;
                leb128u(out_, idx);
                out_ ~= Op.i32_const;
                leb128s(out_, 1);
                out_ ~= (inc ? Op.i32_add : Op.i32_sub);
                out_ ~= Op.local_tee;
                leb128u(out_, idx);
            }
            return;
        }

        // Check for global variable
        Symbol symbol = emitter.symbolTable.lookupSymbol(ident.name);
        if (symbol) {
            if (auto varDecl = cast(VariableDecl)symbol.declaration) {
                if (varDecl.wasmGlobalIndex != uint.max) {
                    auto gIdx = varDecl.wasmGlobalIndex;
                    if (expr.isPostfix) {
                        // Return old value, then modify
                        out_ ~= Op.global_get;
                        leb128u(out_, gIdx);
                        out_ ~= Op.global_get;
                        leb128u(out_, gIdx);
                        out_ ~= Op.i32_const;
                        leb128s(out_, 1);
                        out_ ~= (inc ? Op.i32_add : Op.i32_sub);
                        out_ ~= Op.global_set;
                        leb128u(out_, gIdx);
                    } else {
                        // Modify, then return new value
                        out_ ~= Op.global_get;
                        leb128u(out_, gIdx);
                        out_ ~= Op.i32_const;
                        leb128s(out_, 1);
                        out_ ~= (inc ? Op.i32_add : Op.i32_sub);
                        // global doesn't have tee, so dup before set
                        // store new value in global, leave copy on stack
                        // We need: [newVal] on stack + global = newVal
                        // Emit: compute newVal, global_set, global_get
                        out_ ~= Op.global_set;
                        leb128u(out_, gIdx);
                        out_ ~= Op.global_get;
                        leb128u(out_, gIdx);
                    }
                    return;
                }
            }
        }

        throw new EmitError("Increment/decrement: unknown variable: " ~ ident.name);
    }
    
    void emitCall(ref Appender!(ubyte[]) out_, CallExpression expr) {
        // Handle method calls (obj.method()) - but not UFCS calls
        if (auto memberExpr = cast(MemberExpression)expr.function_) {
            if (expr.isUFCS) {
                // UFCS: obj.func(args...) -> func(obj, args...)
                emitUFCSCall(out_, memberExpr, expr.arguments);
                return;
            }
            emitMethodCall(out_, memberExpr, expr.arguments);
            return;
        }
        
        auto ident = cast(IdentifierExpression)expr.function_;
        if (!ident) {
            throw new EmitError("Indirect calls not yet supported");
        }
        
        // Check if this is struct construction (not a function call)
        auto symbol = emitter.symbolTable.lookupSymbol(ident.name);
        if (symbol && symbol.kind == SymbolKind.Type) {
            if (auto structDecl = symbol.type.asStruct()) {
                // Guard: opCall overloads not yet supported
                foreach (member; structDecl.members) {
                    if (auto fd = cast(FunctionDecl)member) {
                        assert(fd.name != "opCall",
                            "opCall overloads not yet supported");
                    }
                }
                // Allocate temp, initialize, return pointer
                emitStructConstructionToTemp(out_, structDecl, expr.arguments);
                return;
            }
        }
        
        // Special handling for __writeln: lower to typed CTFE print calls
        if (ident.name == "__writeln") {
            emitWritelnCall(out_, expr.arguments);
            return;
        }

        // Compiler intrinsics — emit raw opcodes, no function call
        if (ident.name.length > 12 && ident.name[0..12] == "__intrinsic_") {
            emitIntrinsicCall(out_, ident.name, expr.arguments);
            return;
        }
        
        // Get callee's parameter types for interface conversion detection
        // Use IFTI resolved name if available
        string calleeLookup = expr.resolvedInstantiation ? expr.resolvedInstantiation.name : ident.name;
        FunctionDecl calleeDecl = null;
        if (auto funcInfo = calleeLookup in emitter.funcIndex) {
            if (*funcInfo < emitter.functions.length) {
                calleeDecl = emitter.functions[*funcInfo].decl;
            }
        }

        // Check if callee returns aggregate via hidden pointer
        bool calleeHasLargeReturn = false;
        uint resultTempSize = 0;
        if (calleeDecl && emitter.isLargeReturnType(calleeDecl.returnType)) {
            calleeHasLargeReturn = true;
            resultTempSize = computeLargeReturnSize(calleeDecl.returnType);

            // Allocate temp for result: SP = SP - resultSize
            out_ ~= Op.global_get;
            leb128u(out_, emitter.spGlobal);
            out_ ~= Op.i32_const;
            leb128s(out_, resultTempSize);
            out_ ~= Op.i32_sub;
            out_ ~= Op.global_set;
            leb128u(out_, emitter.spGlobal);

            // Push result pointer as first hidden argument
            out_ ~= Op.global_get;
            leb128u(out_, emitter.spGlobal);
        }

        // Push hidden arena pointer if callee needs it
        // (exported free functions like "main" don't take arena param)
        bool calleeNeedsArena = (calleeDecl && calleeDecl.needsArena && calleeDecl.name != "main")
                || (expr.resolvedInstantiation && expr.resolvedInstantiation.needsArena);
        if (calleeNeedsArena) {
            emitArenaPointer(out_);
        }

        // Emit arguments (copy structs for pass-by-value semantics)
        uint totalCopySize = 0;
        foreach (argIdx, arg; expr.arguments) {
            // Check if argument is a struct/staticArray/slice that needs copying
            if (auto argIdent = cast(IdentifierExpression)arg) {
                if (auto argInfo = resolveVar(argIdent.resolvedLocalId, argIdent.name)) {
                    if (argInfo.isStruct) {
                        // Struct - copy to temp, pass temp address
                        auto structDecl = argInfo.structDecl;
                        uint structSize = cast(uint)structDecl.structSize;

                        // Allocate temp: SP = SP - structSize
                        out_ ~= Op.global_get;
                        leb128u(out_, emitter.spGlobal);
                        out_ ~= Op.i32_const;
                        leb128s(out_, structSize);
                        out_ ~= Op.i32_sub;
                        out_ ~= Op.global_set;
                        leb128u(out_, emitter.spGlobal);

                        // Copy fields from source to SP
                        foreach (field; structDecl.fields) {
                            // Dest: SP + fieldOffset
                            out_ ~= Op.global_get;
                            leb128u(out_, emitter.spGlobal);
                            if (field.offset > 0) {
                                out_ ~= Op.i32_const;
                                leb128s(out_, cast(int)field.offset);
                                out_ ~= Op.i32_add;
                            }

                            // Src: var address + fieldOffset
                            emitVarAddress(out_, argInfo);
                            if (field.offset > 0) {
                                out_ ~= Op.i32_const;
                                leb128s(out_, cast(int)field.offset);
                                out_ ~= Op.i32_add;
                            }
                            out_ ~= Op.i32_load;
                            out_ ~= cast(ubyte)0x02;
                            leb128u(out_, 0);

                            // Store
                            out_ ~= Op.i32_store;
                            out_ ~= cast(ubyte)0x02;
                            leb128u(out_, 0);
                        }

                        // Push SP (address of copy) as argument
                        out_ ~= Op.global_get;
                        leb128u(out_, emitter.spGlobal);

                        totalCopySize += structSize;
                        continue;
                    }

                    if (argInfo.isStaticArray) {
                        // Static array - copy to temp, pass temp address
                        uint arrSize = argInfo.elementCount * argInfo.elementSize;

                        out_ ~= Op.global_get;
                        leb128u(out_, emitter.spGlobal);
                        out_ ~= Op.i32_const;
                        leb128s(out_, arrSize);
                        out_ ~= Op.i32_sub;
                        out_ ~= Op.global_set;
                        leb128u(out_, emitter.spGlobal);

                        // Copy word by word
                        for (uint off = 0; off < arrSize; off += 4) {
                            out_ ~= Op.global_get;
                            leb128u(out_, emitter.spGlobal);
                            if (off > 0) {
                                out_ ~= Op.i32_const;
                                leb128s(out_, off);
                                out_ ~= Op.i32_add;
                            }

                            emitVarAddress(out_, argInfo);
                            if (off > 0) {
                                out_ ~= Op.i32_const;
                                leb128s(out_, cast(int)off);
                                out_ ~= Op.i32_add;
                            }
                            out_ ~= Op.i32_load;
                            out_ ~= cast(ubyte)0x02;
                            leb128u(out_, 0);

                            out_ ~= Op.i32_store;
                            out_ ~= cast(ubyte)0x02;
                            leb128u(out_, 0);
                        }

                        out_ ~= Op.global_get;
                        leb128u(out_, emitter.spGlobal);

                        totalCopySize += arrSize;
                        continue;
                    }

                    if (argInfo.isSlice) {
                        // Slice - copy 12-byte slice struct to temp, pass temp address
                        const sliceSize = sliceLayout.totalSize;

                        out_ ~= Op.global_get;
                        leb128u(out_, emitter.spGlobal);
                        out_ ~= Op.i32_const;
                        leb128s(out_, sliceSize);
                        out_ ~= Op.i32_sub;
                        out_ ~= Op.global_set;
                        leb128u(out_, emitter.spGlobal);

                        // Copy 3 fields (ptr, length, capacity)
                        foreach (fieldOffset; [0, 4, 8]) {
                            out_ ~= Op.global_get;
                            leb128u(out_, emitter.spGlobal);
                            if (fieldOffset > 0) {
                                out_ ~= Op.i32_const;
                                leb128s(out_, fieldOffset);
                                out_ ~= Op.i32_add;
                            }

                            emitVarAddress(out_, argInfo);
                            if (fieldOffset > 0) {
                                out_ ~= Op.i32_const;
                                leb128s(out_, fieldOffset);
                                out_ ~= Op.i32_add;
                            }
                            out_ ~= Op.i32_load;
                            out_ ~= cast(ubyte)0x02;
                            leb128u(out_, 0);

                            out_ ~= Op.i32_store;
                            out_ ~= cast(ubyte)0x02;
                            leb128u(out_, 0);
                        }

                        out_ ~= Op.global_get;
                        leb128u(out_, emitter.spGlobal);

                        totalCopySize += sliceSize;
                        continue;
                    }
                }
            }

            // Check for class→interface conversion (fat pointer)
            if (calleeDecl && argIdx < calleeDecl.parameters.length) {
                auto paramType = calleeDecl.parameters[argIdx].type;
                if (auto ifaceDecl = paramType.asInterface()) {
                    if (auto argIdent = cast(IdentifierExpression)arg) {
                        if (auto classInfo = resolveVar(argIdent.resolvedLocalId, argIdent.name)) {
                            if (classInfo.isClass) {
                                // Class → interface: emit fat pointer (obj_ptr, itable_ptr)
                                emitVarAddress(out_, classInfo);

                                auto classDecl = classInfo.classDecl;
                                if (auto itableBase = ifaceDecl.name in classDecl.itableBases) {
                                    out_ ~= Op.i32_const;
                                    leb128u(out_, *itableBase);
                                } else {
                                    throw new EmitError("Class " ~ classDecl.name ~
                                        " does not implement interface " ~ ifaceDecl.name);
                                }
                                continue;
                            }
                        }
                    }
                }
            }

            // Check for slice expression argument (e.g., data[1..4])
            if (auto sliceArg = cast(SliceExpression)arg) {
                auto sourceIdent = cast(IdentifierExpression)sliceArg.array;
                if (!sourceIdent) {
                    throw new EmitError("Complex slice source not supported in call argument");
                }

                auto srcInfo = resolveVar(sourceIdent.resolvedLocalId, sourceIdent.name);
                if (!srcInfo || (!srcInfo.isSlice && !srcInfo.isStaticArray)) {
                    throw new EmitError("Can only sub-slice array-like variables: " ~ sourceIdent.name);
                }
                uint sourceElemSize = srcInfo.elementSize;

                const sliceSize = sliceLayout.totalSize;

                // Allocate temp: SP = SP - 12
                out_ ~= Op.global_get;
                leb128u(out_, emitter.spGlobal);
                out_ ~= Op.i32_const;
                leb128s(out_, sliceSize);
                out_ ~= Op.i32_sub;
                out_ ~= Op.global_set;
                leb128u(out_, emitter.spGlobal);

                // Store ptr = base + start * elemSize at SP+0
                out_ ~= Op.global_get;
                leb128u(out_, emitter.spGlobal);

                // Load base address
                if (srcInfo.isSlice) {
                    emitVarAddress(out_, srcInfo);
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);  // load .ptr field
                } else {
                    // Static array: address IS the data
                    emitVarAddress(out_, srcInfo);
                }

                // Add start * elemSize
                emitExpression(out_, sliceArg.start);
                out_ ~= Op.i32_const;
                leb128s(out_, sourceElemSize);
                out_ ~= Op.i32_mul;
                out_ ~= Op.i32_add;

                out_ ~= Op.i32_store;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);

                // Store length = end - start at SP+4
                out_ ~= Op.global_get;
                leb128u(out_, emitter.spGlobal);
                out_ ~= Op.i32_const;
                leb128s(out_, sliceLayout.lengthOffset);
                out_ ~= Op.i32_add;

                emitExpression(out_, sliceArg.end);
                emitExpression(out_, sliceArg.start);
                out_ ~= Op.i32_sub;

                out_ ~= Op.i32_store;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);

                // Store capacity = length at SP+8
                out_ ~= Op.global_get;
                leb128u(out_, emitter.spGlobal);
                out_ ~= Op.i32_const;
                leb128s(out_, sliceLayout.capacityOffset);
                out_ ~= Op.i32_add;

                emitExpression(out_, sliceArg.end);
                emitExpression(out_, sliceArg.start);
                out_ ~= Op.i32_sub;

                out_ ~= Op.i32_store;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);

                // Push SP (address of temp slice) as argument
                out_ ~= Op.global_get;
                leb128u(out_, emitter.spGlobal);

                totalCopySize += sliceSize;
                continue;
            }

            // Non-struct argument
            emitExpression(out_, arg);
        }
        
        // Call — use IFTI resolved name if available
        string callName = expr.resolvedInstantiation ? expr.resolvedInstantiation.name : ident.name;
        uint funcIdx = emitter.getFuncIndex(callName);
        out_ ~= Op.call;
        leb128u(out_, funcIdx);
        
        // Restore SP after call (deallocate arg copies only, not result temp)
        if (totalCopySize > 0) {
            out_ ~= Op.global_get;
            leb128u(out_, emitter.spGlobal);
            out_ ~= Op.i32_const;
            leb128s(out_, totalCopySize);
            out_ ~= Op.i32_add;
            out_ ~= Op.global_set;
            leb128u(out_, emitter.spGlobal);
        }

        // For aggregate-returning functions, leave result address on WASM stack
        // (result temp persists until function epilogue, like emitStructConstructionToTemp)
        if (calleeHasLargeReturn) {
            out_ ~= Op.global_get;
            leb128u(out_, emitter.spGlobal);
        }
    }
    
    /**
     * Emit a template instantiation call: max!int(3, 5)
     * The resolved instantiation has a mangled name that the emitter collected.
     */
    void emitTemplateCall(ref Appender!(ubyte[]) out_, TemplateInstantiationExpression expr) {
        // Struct template construction: Pair!(int, int)(10, 20)
        if (expr.resolvedStructInstantiation) {
            emitStructConstructionToTemp(out_, expr.resolvedStructInstantiation, expr.callArguments);
            return;
        }

        auto inst = expr.resolvedInstantiation;
        if (!inst)
            throw new EmitError("Template instantiation not resolved: " ~ expr.templateName);

        // Emit call arguments
        foreach (arg; expr.callArguments) {
            emitExpression(out_, arg);
        }

        // Call the mangled function
        uint funcIdx = emitter.getFuncIndex(inst.name);
        out_ ~= Op.call;
        leb128u(out_, funcIdx);
    }

    /**
     * Emit a compiler intrinsic — raw opcode, no function call overhead.
     */
    void emitIntrinsicCall(ref Appender!(ubyte[]) out_, string name, Expression[] arguments) {
        // Emit arguments
        foreach (arg; arguments) {
            emitExpression(out_, arg);
        }

        // Dispatch to raw opcode
        if (name == "__intrinsic_shl") {
            out_ ~= Op.i32_shl;
        } else if (name == "__intrinsic_shr_s") {
            out_ ~= Op.i32_shr_s;
        } else if (name == "__intrinsic_shr_u") {
            out_ ~= Op.i32_shr_u;
        } else if (name == "__intrinsic_unreachable") {
            out_ ~= Op.unreachable;
        } else {
            throw new EmitError("Unknown intrinsic: " ~ name);
        }
    }

    /**
     * Emit __writeln(args...) by lowering to typed CTFE write calls.
     * Each argument is printed according to its type, followed by a newline.
     * Uses __ctfe_write_* (building blocks without prefix) not __ctfe_print_*.
     */
    void emitWritelnCall(ref Appender!(ubyte[]) out_, Expression[] args) {
        foreach (arg; args) {
            // Determine argument type and emit appropriate write call
            if (auto literal = cast(LiteralExpression)arg) {
                if (literal.value.type == typeid(string)) {
                    // String literal: emit __ctfe_write_str(ptr, len)
                    string strVal = literal.value.get!string();
                    uint structAddr = emitter.registerArrayLiteral(strVal);
                    
                    // Load ptr from struct (offset 0)
                    out_ ~= Op.i32_const;
                    leb128u(out_, structAddr);
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;  // align=4
                    leb128u(out_, 0);         // offset=0
                    
                    // Load length from struct (offset 4)
                    out_ ~= Op.i32_const;
                    leb128u(out_, structAddr + 4);
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    
                    // Call __ctfe_write_str
                    emitter.neededCTFEImports["__ctfe_write_str"] = true;
                    uint funcIdx = emitter.getFuncIndex("__ctfe_write_str");
                    out_ ~= Op.call;
                    leb128u(out_, funcIdx);
                }
                else if (literal.value.type == typeid(long) || literal.value.type == typeid(int)) {
                    // Integer literal: emit __ctfe_write_i32(value)
                    long val = literal.value.type == typeid(long) 
                        ? literal.value.get!long() 
                        : literal.value.get!int();
                    out_ ~= Op.i32_const;
                    leb128s(out_, cast(int)val);
                    
                    emitter.neededCTFEImports["__ctfe_write_i32"] = true;
                    uint funcIdx = emitter.getFuncIndex("__ctfe_write_i32");
                    out_ ~= Op.call;
                    leb128u(out_, funcIdx);
                }
                else if (literal.value.type == typeid(double)) {
                    // Float literal: emit __ctfe_write_f64(value)
                    double val = literal.value.get!double();
                    out_ ~= Op.f64_const;
                    out_ ~= (cast(ubyte*)&val)[0 .. 8];

                    emitter.neededCTFEImports["__ctfe_write_f64"] = true;
                    uint funcIdx = emitter.getFuncIndex("__ctfe_write_f64");
                    out_ ~= Op.call;
                    leb128u(out_, funcIdx);
                }
                else if (literal.value.type == typeid(bool)) {
                    // Boolean literal: emit __ctfe_write_bool(0 or 1)
                    bool val = literal.value.get!bool();
                    out_ ~= Op.i32_const;
                    leb128s(out_, val ? 1 : 0);

                    emitter.neededCTFEImports["__ctfe_write_bool"] = true;
                    uint funcIdx = emitter.getFuncIndex("__ctfe_write_bool");
                    out_ ~= Op.call;
                    leb128u(out_, funcIdx);
                }
            }
            else if (auto manifestStr = getStringManifest(arg)) {
                // String manifest constant — resolve value and emit like string literal
                if (!manifestStr.ctfeComplete)
                    emitter.symbolTable.resolveManifestValue(manifestStr);
                uint structAddr = emitter.registerArrayLiteral(manifestStr.ctfeStringValue);

                // Load ptr from struct (offset 0)
                out_ ~= Op.i32_const;
                leb128u(out_, structAddr);
                out_ ~= Op.i32_load;
                out_ ~= cast(ubyte)0x02;  // align=4
                leb128u(out_, 0);          // offset=0

                // Load length from struct (offset 4)
                out_ ~= Op.i32_const;
                leb128u(out_, structAddr + 4);
                out_ ~= Op.i32_load;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);

                emitter.neededCTFEImports["__ctfe_write_str"] = true;
                uint funcIdx = emitter.getFuncIndex("__ctfe_write_str");
                out_ ~= Op.call;
                leb128u(out_, funcIdx);
            }
            else if (auto manifestFloat = getFloatManifest(arg)) {
                // Float manifest constant — emit f64_const + __ctfe_write_f64
                if (!manifestFloat.ctfeComplete)
                    emitter.symbolTable.resolveManifestValue(manifestFloat);
                double val = manifestFloat.ctfeFloatValue;
                out_ ~= Op.f64_const;
                out_ ~= (cast(ubyte*)&val)[0 .. 8];

                emitter.neededCTFEImports["__ctfe_write_f64"] = true;
                uint funcIdx = emitter.getFuncIndex("__ctfe_write_f64");
                out_ ~= Op.call;
                leb128u(out_, funcIdx);
            }
            else {
                // Non-literal, non-string expression: evaluate and print as i32
                emitExpression(out_, arg);

                emitter.neededCTFEImports["__ctfe_write_i32"] = true;
                uint funcIdx = emitter.getFuncIndex("__ctfe_write_i32");
                out_ ~= Op.call;
                leb128u(out_, funcIdx);
            }
        }
        
        // Emit newline at the end
        emitter.neededCTFEImports["__ctfe_write_newline"] = true;
        uint newlineIdx = emitter.getFuncIndex("__ctfe_write_newline");
        out_ ~= Op.call;
        leb128u(out_, newlineIdx);
    }

    /// If expression is an identifier referencing a string manifest constant, return it.
    private ManifestConstantDecl getStringManifest(Expression arg) {
        if (auto ident = cast(IdentifierExpression)arg) {
            auto symbol = emitter.symbolTable.lookupSymbol(ident.name);
            if (symbol && symbol.isConstant) {
                if (auto manifest = cast(ManifestConstantDecl)symbol.declaration) {
                    if (manifest.isStringType)
                        return manifest;
                }
            }
        }
        return null;
    }

    /// If expression is an identifier referencing a float manifest constant, return it.
    private ManifestConstantDecl getFloatManifest(Expression arg) {
        if (auto ident = cast(IdentifierExpression)arg) {
            auto symbol = emitter.symbolTable.lookupSymbol(ident.name);
            if (symbol && symbol.isConstant) {
                if (auto manifest = cast(ManifestConstantDecl)symbol.declaration) {
                    if (manifest.isFloatType)
                        return manifest;
                }
            }
        }
        return null;
    }

    /**
     * Emit a method call (obj.method(args)).
     * The hidden 'this' pointer is passed as the first argument.
     */
    void emitMethodCall(ref Appender!(ubyte[]) out_, MemberExpression memberExpr, Expression[] args) {
        // Handle __ctfe_runtime magic module calls — emit as imported host function calls
        if (auto objIdent = cast(IdentifierExpression)memberExpr.object) {
            if (objIdent.name == "__ctfe_runtime") {
                // Emit arguments
                foreach (arg; args) {
                    emitExpression(out_, arg);
                }
                // Call the imported function
                string importName = "__ctfe_runtime_" ~ memberExpr.memberName;
                uint funcIdx = emitter.getFuncIndex(importName);
                out_ ~= Op.call;
                leb128u(out_, funcIdx);
                return;
            }
        }

        // Handle nested MemberExpression objects (e.g., obj.field.method() from alias-this)
        if (auto objMember = cast(MemberExpression)memberExpr.object) {
            auto innerType = getMemberExpressionType(objMember);
            if (auto innerStruct = innerType ? innerType.asStruct() : null) {
                // Find the method on the inner struct
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
                    // Emit 'this' pointer: address of the nested member
                    emitMemberAddress(out_, objMember);
                    // Emit arguments
                    foreach (arg; args) {
                        emitExpression(out_, arg);
                    }
                    // Direct call (struct method)
                    uint funcIdx = emitter.getFuncIndex(method.mangledName);
                    out_ ~= Op.call;
                    leb128u(out_, funcIdx);
                    return;
                }
            }
            throw new EmitError("Cannot resolve method '" ~ memberExpr.memberName ~ "' on nested member expression");
        }

        // Get the struct type from the object
        auto objIdent = cast(IdentifierExpression)memberExpr.object;
        if (!objIdent) {
            throw new EmitError("Method call on non-identifier object not yet supported");
        }

        // Unified lookup
        auto objInfo = resolveVar(objIdent.resolvedLocalId, objIdent.name);
        if (objInfo) {
            // Slice built-in methods
            if (objInfo.isSlice) {
                emitSliceBuiltinMethod(out_, objIdent.name, objInfo, memberExpr.memberName, args);
                return;
            }
            // Interface method call (unified: handles both local and param)
            if (objInfo.isInterface) {
                emitInterfaceMethodCall(out_, objInfo, memberExpr.memberName, args);
                return;
            }
        }

        // Find the struct or class declaration to look up the method
        StructDecl structDecl = null;
        ClassDecl classDecl = null;

        if (objInfo) {
            if (objInfo.isStruct) structDecl = objInfo.structDecl;
            else if (objInfo.isClass) classDecl = objInfo.classDecl;
        }

        if (!structDecl && !classDecl) {
            throw new EmitError("Cannot determine type for method call on " ~ objIdent.name);
        }
        
        // Find the method
        FunctionDecl method = null;
        string typeName;
        
        if (structDecl) {
            typeName = structDecl.name;
            foreach (member; structDecl.members) {
                if (auto funcDecl = cast(FunctionDecl)member) {
                    if (funcDecl.name == memberExpr.memberName && funcDecl.isMethod) {
                        method = funcDecl;
                        break;
                    }
                }
            }
        } else if (classDecl) {
            typeName = classDecl.name;
            // Search up inheritance hierarchy for the method
            ClassDecl definingClass = classDecl;
            ClassDecl current = classDecl;
            while (current && !method) {
                foreach (member; current.members) {
                    if (auto funcDecl = cast(FunctionDecl)member) {
                        if (funcDecl.name == memberExpr.memberName && funcDecl.isMethod) {
                            method = funcDecl;
                            definingClass = current;  // Remember where it was defined
                            break;
                        }
                    }
                }
                current = current.baseClassDecl;
            }
            // Use defining class for mangled name lookup
            if (method) {
                typeName = definingClass.name;
            }
        }
        
        if (!method) {
            throw new EmitError("Type '" ~ typeName ~ "' has no method '" ~ memberExpr.memberName ~ "'");
        }
        
        // Emit 'this' pointer as first argument (address of the instance)
        if (objInfo && (objInfo.isStruct || objInfo.isClass)) {
            emitVarAddress(out_, objInfo);
        }

        // Push hidden arena pointer if callee method needs it
        if (method.needsArena) {
            emitArenaPointer(out_);
        }

        // Emit the other arguments
        foreach (arg; args) {
            emitExpression(out_, arg);
        }
        
        // For structs: direct call (no polymorphism)
        // For classes: call_indirect through vtable (virtual dispatch)
        if (structDecl) {
            // Struct method: direct call
            uint funcIdx = emitter.getFuncIndex(method.mangledName);
            out_ ~= Op.call;
            leb128u(out_, funcIdx);
        } else if (classDecl) {
            // Class method: virtual dispatch via call_indirect
            // 1. Find method slot in virtualMethods
            int methodSlot = -1;
            foreach (i, vm; classDecl.virtualMethods) {
                if (vm.name == method.name) {
                    methodSlot = cast(int)i;
                    break;
                }
            }
            
            if (methodSlot < 0) {
                // Not a virtual method (constructor/destructor) - use direct call
                uint funcIdx = emitter.getFuncIndex(method.mangledName);
                out_ ~= Op.call;
                leb128u(out_, funcIdx);
            } else {
                // Virtual dispatch:
                // tableIndex = (vtable_ptr & TABLE_BASE_MASK) + methodSlot
                
                // Load vtable_ptr from object (at offset 0)
                if (objInfo && objInfo.isClass) {
                    emitVarAddress(out_, objInfo);
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                }
                
                // Mask to get tableBase: vtable_ptr & TABLE_BASE_MASK
                out_ ~= Op.i32_const;
                leb128s(out_, cast(int)WasmVtablePacking.TABLE_BASE_MASK);
                out_ ~= Op.i32_and;
                
                // Add method slot
                if (methodSlot > 0) {
                    out_ ~= Op.i32_const;
                    leb128s(out_, methodSlot);
                    out_ ~= Op.i32_add;
                }
                
                // call_indirect with type signature
                uint funcIdx = emitter.getFuncIndex(method.mangledName);
                uint typeIdx = emitter.functions[funcIdx - cast(uint)emitter.imports.length].typeIndex;
                
                out_ ~= Op.call_indirect;
                leb128u(out_, typeIdx);  // type index
                leb128u(out_, 0);         // table index (always 0)
            }
        }
    }
    
    /**
     * Emit interface method call using fat pointer dispatch.
     * Fat pointer layout: { obj_ptr: i32, itable_ptr: i32 }
     * Dispatch: call_indirect at itable[methodSlot] with obj_ptr as 'this'
     */
    void emitInterfaceMethodCall(ref Appender!(ubyte[]) out_, VarInfo* ifaceInfo,
                                  string methodName, Expression[] args) {
        auto ifaceDecl = ifaceInfo.ifaceDecl;

        // Find method slot in interface
        int methodSlot = -1;
        FunctionDecl method = null;
        foreach (i, m; ifaceDecl.methods) {
            if (m.name == methodName) {
                methodSlot = cast(int)i;
                method = m;
                break;
            }
        }

        if (methodSlot < 0 || !method) {
            throw new EmitError("Interface " ~ ifaceDecl.name ~ " has no method " ~ methodName);
        }

        // Emit obj_ptr as 'this' argument
        if (ifaceInfo.addrMode == AddrMode.shadowStack) {
            // Local interface: fat pointer on shadow stack — load obj_ptr from offset 0
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, ifaceInfo.frameOffset);
            out_ ~= Op.i32_add;
            out_ ~= Op.i32_load;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
        } else {
            // Param interface: obj_ptr is a WASM local
            out_ ~= Op.local_get;
            leb128u(out_, ifaceInfo.wasmLocalIdx);
        }

        // Emit other arguments
        foreach (arg; args) {
            emitExpression(out_, arg);
        }

        // Load itable_ptr
        if (ifaceInfo.addrMode == AddrMode.shadowStack) {
            // Local: load from fat pointer at ITABLE_OFFSET
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, ifaceInfo.frameOffset + WasmFatPointerLayout.ITABLE_OFFSET);
            out_ ~= Op.i32_add;
            out_ ~= Op.i32_load;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
        } else {
            // Param: itable is in a separate WASM local
            out_ ~= Op.local_get;
            leb128u(out_, ifaceInfo.itableLocalIdx);
        }

        // Extract itableBase (lower bits via TABLE_BASE_MASK)
        out_ ~= Op.i32_const;
        leb128s(out_, cast(int)WasmVtablePacking.TABLE_BASE_MASK);
        out_ ~= Op.i32_and;

        // Add method slot to get final table index
        if (methodSlot > 0) {
            out_ ~= Op.i32_const;
            leb128s(out_, methodSlot);
            out_ ~= Op.i32_add;
        }

        // call_indirect with method's type signature
        uint typeIdx = getMethodTypeIndex(method);

        out_ ~= Op.call_indirect;
        leb128u(out_, typeIdx);
        leb128u(out_, 0);  // table index (always 0)
    }

    /**
     * Get or create a type index for a method signature
     */
    private uint getMethodTypeIndex(FunctionDecl method) {
        return emitter.getOrCreateMethodType(method);
    }
    
    /**
     * Emit a UFCS call (obj.func(args...) -> func(obj, args...)).
     * The object is passed as the first argument to the free function.
     */
    void emitUFCSCall(ref Appender!(ubyte[]) out_, MemberExpression memberExpr, Expression[] args) {
        // Emit the object as the first argument
        emitExpression(out_, memberExpr.object);
        
        // Emit the remaining arguments
        foreach (arg; args) {
            emitExpression(out_, arg);
        }
        
        // Call the free function by name
        uint funcIdx = emitter.getFuncIndex(memberExpr.memberName);
        out_ ~= Op.call;
        leb128u(out_, funcIdx);
    }
    
    /**
     * Compute the size in bytes for a large return type (struct or static array).
     * Used by both emitCall and emitStructReturnCall to allocate result space.
     */
    uint computeLargeReturnSize(Type returnType) {
        if (auto arrType = cast(ArrayType)returnType) {
            if (arrType.arraySize !is null) {
                uint elemCount = evaluateStaticArraySize(arrType.arraySize);
                size_t elemSize = arrType.elementType.size();
                if (elemSize == 0) elemSize = 4;
                return elemCount * cast(uint)elemSize;
            }
            return sliceLayout.totalSize;
        }
        if (auto sd = returnType.asStruct())
            return cast(uint)sd.structSize;
        return cast(uint)returnType.size();
    }

    /**
     * Emit a call to a function that returns an aggregate (struct/static array)
     * via hidden result pointer. The destination frame address is passed directly
     * as the hidden first parameter, so the callee writes into the caller's frame.
     */
    void emitStructReturnCall(ref Appender!(ubyte[]) out_, string funcName,
                              Expression[] args, int resultFrameOffset) {
        // Push hidden result pointer as first argument: FP + resultFrameOffset
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        if (resultFrameOffset != 0) {
            out_ ~= Op.i32_const;
            leb128s(out_, resultFrameOffset);
            out_ ~= Op.i32_add;
        }

        // Push hidden arena pointer if callee needs it
        // Parameter order: [result_ptr] [arena?] [user_args...]
        if (auto fi = funcName in emitter.funcIndex) {
            if (*fi < emitter.functions.length) {
                auto calleeDecl = emitter.functions[*fi].decl;
                if (calleeDecl.needsArena && calleeDecl.name != "main") {
                    emitArenaPointer(out_);
                }
            }
        }

        // Emit arguments (with struct/slice pass-by-value handling)
        uint totalCopySize = 0;
        foreach (arg; args) {
            if (auto argIdent = cast(IdentifierExpression)arg) {
                auto argInfo = resolveVar(argIdent.resolvedLocalId, argIdent.name);
                if (argInfo && argInfo.isStruct) {
                    auto argStructDecl = argInfo.structDecl;
                    uint structSize = cast(uint)argStructDecl.structSize;

                    // Allocate temp: SP = SP - structSize
                    out_ ~= Op.global_get;
                    leb128u(out_, emitter.spGlobal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, structSize);
                    out_ ~= Op.i32_sub;
                    out_ ~= Op.global_set;
                    leb128u(out_, emitter.spGlobal);

                    // Copy fields from source to temp
                    foreach (field; argStructDecl.fields) {
                        out_ ~= Op.global_get;
                        leb128u(out_, emitter.spGlobal);
                        if (field.offset > 0) {
                            out_ ~= Op.i32_const;
                            leb128s(out_, cast(int)field.offset);
                            out_ ~= Op.i32_add;
                        }
                        emitVarAddress(out_, argInfo);
                        if (field.offset > 0) {
                            out_ ~= Op.i32_const;
                            leb128s(out_, cast(int)field.offset);
                            out_ ~= Op.i32_add;
                        }
                        out_ ~= Op.i32_load;
                        out_ ~= cast(ubyte)0x02;
                        leb128u(out_, 0);
                        out_ ~= Op.i32_store;
                        out_ ~= cast(ubyte)0x02;
                        leb128u(out_, 0);
                    }

                    out_ ~= Op.global_get;
                    leb128u(out_, emitter.spGlobal);
                    totalCopySize += structSize;
                    continue;
                }
            }

            // Non-aggregate argument
            emitExpression(out_, arg);
        }

        // Call
        uint funcIdx = emitter.getFuncIndex(funcName);
        out_ ~= Op.call;
        leb128u(out_, funcIdx);

        // Deallocate arg copies (not the result — that lives in the caller's frame)
        if (totalCopySize > 0) {
            out_ ~= Op.global_get;
            leb128u(out_, emitter.spGlobal);
            out_ ~= Op.i32_const;
            leb128s(out_, totalCopySize);
            out_ ~= Op.i32_add;
            out_ ~= Op.global_set;
            leb128u(out_, emitter.spGlobal);
        }
    }

    /**
     * Emit struct construction to a temporary on shadow stack.
     * Leaves pointer to the struct on the value stack.
     */
    void emitStructConstructionToTemp(ref Appender!(ubyte[]) out_, StructDecl structDecl, Expression[] args) {
        uint structSize = cast(uint)structDecl.structSize;
        
        // Allocate space: SP = SP - structSize
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, structSize);
        out_ ~= Op.i32_sub;
        out_ ~= Op.global_set;
        leb128u(out_, emitter.spGlobal);
        
        // Initialize at base address = current SP
        emitStructFieldsInit(out_, structDecl, args, EmitAddrMode.fromSP, 0);
        
        // Leave pointer to struct on stack
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
    }
    
    // How to compute the destination address for a field
    enum EmitAddrMode { fromSP, fromFP }
    
    /**
     * Initialize struct fields at a base address.
     * baseMode determines how to compute the address.
     */
    void emitStructFieldsInit(ref Appender!(ubyte[]) out_, StructDecl structDecl, 
                              Expression[] args, EmitAddrMode baseMode, int baseOffset) {
        for (size_t i = 0; i < structDecl.fields.length && i < args.length; i++) {
            auto field = structDecl.fields[i];
            int fieldAddr = baseOffset + cast(int)field.offset;
            
            // Check if argument is nested struct construction
            if (auto callArg = cast(CallExpression)args[i]) {
                if (auto argIdent = cast(IdentifierExpression)callArg.function_) {
                    auto argSymbol = emitter.symbolTable.lookupSymbol(argIdent.name);
                    if (argSymbol && argSymbol.kind == SymbolKind.Type) {
                        if (auto nestedDecl = argSymbol.type.asStruct()) {
                            // Recurse: initialize nested struct directly at fieldAddr
                            emitStructFieldsInit(out_, nestedDecl, callArg.arguments,
                                                baseMode, fieldAddr);
                            continue;
                        }
                    }
                }
            }
            
            // Aggregate types (structs, classes, static arrays) are passed by address
            // emitExpression for these types yields an ADDRESS, not a value
            uint valueSize = cast(uint)field.type.size();
            if (field.type.isAggregate() && valueSize > 0) {
                // Emit source address
                emitExpression(out_, args[i]);  // Stack: [src_addr]
                
                // Copy word by word
                for (uint off = 0; off < valueSize; off += 4) {
                    // Destination address
                    if (baseMode == EmitAddrMode.fromFP) {
                        out_ ~= Op.local_get;
                        leb128u(out_, fpLocal);
                    } else {
                        out_ ~= Op.global_get;
                        leb128u(out_, emitter.spGlobal);
                    }
                    int destOff = fieldAddr + cast(int)off;
                    if (destOff != 0) {
                        out_ ~= Op.i32_const;
                        leb128s(out_, destOff);
                        out_ ~= Op.i32_add;
                    }
                    
                    // Load from source: duplicate src_addr, add offset, load
                    emitExpression(out_, args[i]);  // Stack: [dest_addr, src_addr]
                    if (off != 0) {
                        out_ ~= Op.i32_const;
                        leb128s(out_, cast(int)off);
                        out_ ~= Op.i32_add;
                    }
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    
                    // Store to destination: Stack: [dest_addr, value]
                    out_ ~= Op.i32_store;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                }
                continue;
            }
            
            // Emit destination address based on mode
            if (baseMode == EmitAddrMode.fromFP) {
                out_ ~= Op.local_get;
                leb128u(out_, fpLocal);
            } else {
                out_ ~= Op.global_get;
                leb128u(out_, emitter.spGlobal);
            }
            if (fieldAddr != 0) {
                out_ ~= Op.i32_const;
                leb128s(out_, fieldAddr);
                out_ ~= Op.i32_add;
            }
            
            // Emit value
            emitExpression(out_, args[i]);
            
            // Store
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
        }
    }
    
    void emitAssignment(ref Appender!(ubyte[]) out_, AssignmentExpression expr) {
        // Check for slice append (arr ~= value)
        if (expr.operator == AssignmentExpression.Operator.ConcatAssign) {
            auto ident = cast(IdentifierExpression)expr.left;
            if (ident) {
                if (auto si = resolveVar(ident.resolvedLocalId, ident.name)) {
                    if (si.isSlice) {
                        emitSliceAppend(out_, ident.name, si, expr.right);
                        return;
                    }
                }
                // Implicit field access in method: field ~= value
                if (auto thisInfo = resolveVar(THIS_LOCAL_ID, "this")) {
                    AggregateDecl parent = func.structParent ? cast(AggregateDecl)func.structParent
                                                             : cast(AggregateDecl)func.classParent;
                    if (parent) {
                        auto field = parent.getField(ident.name);
                        if (field) {
                            if (auto arrType = cast(ArrayType)field.type) {
                                if (!arrType.isStaticArray) {
                                    emitSliceFieldAppend(out_, thisInfo, cast(int)field.offset,
                                        arrType, expr.right);
                                    return;
                                }
                            }
                        }
                    }
                }
            }
            // Explicit member expression: s.data ~= value
            if (auto memberExpr = cast(MemberExpression)expr.left) {
                if (auto identObj = cast(IdentifierExpression)memberExpr.object) {
                    if (auto structInfo = resolveVar(identObj.resolvedLocalId, identObj.name)) {
                        if (structInfo.isStruct) {
                            auto field = structInfo.structDecl.getField(memberExpr.memberName);
                            if (field) {
                                if (auto arrType = cast(ArrayType)field.type) {
                                    if (!arrType.isStaticArray) {
                                        emitSliceFieldAppend(out_, structInfo, cast(int)field.offset,
                                            arrType, expr.right);
                                        return;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            throw new EmitError("Concat-assign (~=) only supported on slice locals/fields");
        }

        // Check for struct field assignment (p.x = value)
        if (auto member = cast(MemberExpression)expr.left) {
            emitMemberAssignment(out_, member, expr.right);
            return;
        }

        // Check for index assignment (arr[i] = value)
        if (auto indexExpr = cast(IndexExpression)expr.left) {
            emitIndexAssignment(out_, indexExpr, expr.right);
            return;
        }

        auto ident = cast(IdentifierExpression)expr.left;
        if (!ident) {
            throw new EmitError("Complex assignment targets not yet supported");
        }

        // Check for implicit field assignment in a method (fieldName = value)
        if (func.structParent !is null || func.classParent !is null) {
            AggregateDecl parent = func.structParent ? cast(AggregateDecl)func.structParent
                                                     : cast(AggregateDecl)func.classParent;
            auto field = parent.getField(ident.name);
            if (field) {
                // Implicit this.fieldName = value
                if (auto thisInfo = resolveVar(THIS_LOCAL_ID, "this")) {
                    out_ ~= Op.local_get;
                    leb128u(out_, thisInfo.wasmLocalIdx);
                    if (field.offset > 0) {
                        out_ ~= Op.i32_const;
                        leb128s(out_, cast(int)field.offset);
                        out_ ~= Op.i32_add;
                    }
                    emitExpression(out_, expr.right);
                    out_ ~= Op.i32_store;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    emitExpression(out_, expr.right);
                    return;
                }
            }
        }

        // Unified variable resolution for locals and params
        if (auto info = resolveVar(ident.resolvedLocalId, ident.name)) {
            if (info.addrMode == AddrMode.wasmLocal) {
                // Scalar local/param — local_set/local_tee
                auto wasmIdx = info.wasmLocalIdx;
                if (expr.loweredCall) {
                    emitExpression(out_, expr.loweredCall);
                } else if (expr.operator != AssignmentExpression.Operator.Assign) {
                    out_ ~= Op.local_get;
                    leb128u(out_, wasmIdx);
                    emitExpression(out_, expr.right);
                    emitCompoundOp(out_, expr.operator);
                } else {
                    emitExpression(out_, expr.right);
                }
                out_ ~= Op.local_tee;
                leb128u(out_, wasmIdx);
                return;
            }
            // Shadow stack / param pointer assignments handled via other paths
            // (struct/class/slice assignments go through member/index assignment)
        }

        // Check for scalar global variable
        Symbol symbol = emitter.symbolTable.lookupSymbol(ident.name);
        if (symbol) {
            if (auto varDecl = cast(VariableDecl)symbol.declaration) {
                if (varDecl.wasmGlobalIndex != uint.max) {
                    if (expr.loweredCall) {
                        emitExpression(out_, expr.loweredCall);
                    } else if (expr.operator != AssignmentExpression.Operator.Assign) {
                        out_ ~= Op.global_get;
                        leb128u(out_, varDecl.wasmGlobalIndex);
                        emitExpression(out_, expr.right);
                        emitCompoundOp(out_, expr.operator);
                    } else {
                        emitExpression(out_, expr.right);
                    }
                    out_ ~= Op.global_set;
                    leb128u(out_, varDecl.wasmGlobalIndex);
                    out_ ~= Op.global_get;
                    leb128u(out_, varDecl.wasmGlobalIndex);
                    return;
                }
                // Global exists but wasn't collected — happens during CTFE
                throw new EmitError(
                    "Cannot access module-level variable '" ~ ident.name ~ "' during CTFE",
                    ident.location);
            }
        }
        throw new EmitError("Unknown identifier in assignment: " ~ ident.name, ident.location);
    }

    /// Emit the compound operation for compound assignment operators.
    private void emitCompoundOp(ref Appender!(ubyte[]) out_, AssignmentExpression.Operator op) {
        final switch (op) {
            case AssignmentExpression.Operator.Assign:
                assert(0, "emitCompoundOp called with Assign");
            case AssignmentExpression.Operator.AddAssign: out_ ~= Op.i32_add; break;
            case AssignmentExpression.Operator.SubtractAssign: out_ ~= Op.i32_sub; break;
            case AssignmentExpression.Operator.MultiplyAssign: out_ ~= Op.i32_mul; break;
            case AssignmentExpression.Operator.DivideAssign: out_ ~= Op.i32_div_s; break;
            case AssignmentExpression.Operator.ModuloAssign: out_ ~= Op.i32_rem_s; break;
            case AssignmentExpression.Operator.AndAssign: out_ ~= Op.i32_and; break;
            case AssignmentExpression.Operator.OrAssign: out_ ~= Op.i32_or; break;
            case AssignmentExpression.Operator.XorAssign: out_ ~= Op.i32_xor; break;
            case AssignmentExpression.Operator.ShiftLeftAssign:
                assert(0, "<<= should be lowered to opShiftLeft call");
            case AssignmentExpression.Operator.ShiftRightAssign:
                assert(0, ">>= should be lowered to opShiftRight call");
            case AssignmentExpression.Operator.ConcatAssign:
                throw new EmitError("~= should use slice path");
        }
    }
    
    /**
     * Emit assignment to a struct field (p.x = value)
     */
    void emitMemberAssignment(ref Appender!(ubyte[]) out_, MemberExpression member, Expression value) {
        // Handle index expression objects (points[i].x = value)
        if (auto indexExpr = cast(IndexExpression)member.object) {
            // Emit element address (aggregate mode leaves address on stack)
            emitIntrinsicOpIndex(out_, indexExpr);
            auto elemType = getIndexExpressionElementType(indexExpr);
            if (auto structDecl = elemType.asStruct()) {
                auto field = structDecl.getField(member.memberName);
                if (field) {
                    if (field.offset > 0) {
                        out_ ~= Op.i32_const;
                        leb128s(out_, cast(int)field.offset);
                        out_ ~= Op.i32_add;
                    }
                    emitExpression(out_, value);
                    out_ ~= Op.i32_store;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    // Re-emit value for expression result
                    emitExpression(out_, value);
                    return;
                }
            }
        }

        auto objIdent = cast(IdentifierExpression)member.object;
        if (!objIdent) {
            throw new EmitError("Complex member assignment targets not yet supported");
        }
        
        // Unified variable lookup
        if (auto info = resolveVar(objIdent.resolvedLocalId, objIdent.name)) {
            if (info.isStruct || info.isClass) {
                auto aggr = info.isStruct ? cast(AggregateDecl)info.structDecl
                                          : cast(AggregateDecl)info.classDecl;
                auto field = aggr.getField(member.memberName);
                if (!field) {
                    throw new EmitError(format("Unknown field '%s' in '%s'",
                                              member.memberName, aggr.name));
                }

                // Store: addr + value
                emitVarAddress(out_, info);
                if (field.offset > 0) {
                    out_ ~= Op.i32_const;
                    leb128s(out_, cast(int)field.offset);
                    out_ ~= Op.i32_add;
                }
                emitExpression(out_, value);
                out_ ~= Op.i32_store;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);

                // Re-load for expression value
                emitVarAddress(out_, info);
                if (field.offset > 0) {
                    out_ ~= Op.i32_const;
                    leb128s(out_, cast(int)field.offset);
                    out_ ~= Op.i32_add;
                }
                out_ ~= Op.i32_load;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
                return;
            }

            // Slice .length assignment
            if (info.isSlice && member.memberName == "length") {
                emitSliceLengthAssignment(out_, objIdent.name, info, value);
                return;
            }
        }
        
        throw new EmitError("Unsupported member assignment target", member.toString());
    }
    
    /**
     * Emit arr.length = newLength
     * 
     * If newLength > capacity: reserve(newLength) first
     * If newLength > oldLength: zero-initialize new elements
     * Update length field
     * 
     * Uses temp storage at SP-4 (newLength), SP-8 (newBuffer), SP-12 (loop counter)
     */
    void emitSliceLengthAssignment(ref Appender!(ubyte[]) out_, string sliceName,
                                    VarInfo* sliceInfo, Expression newLengthExpr) {
        int sliceAddr = sliceInfo.frameOffset;
        
        // Store newLength at SP-4
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        out_ ~= Op.i32_sub;
        emitExpression(out_, newLengthExpr);
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        // Load current capacity
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + sliceLayout.capacityOffset);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        // Load newLength for comparison
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        // if (capacity < newLength) - need to reserve
        out_ ~= Op.i32_lt_u;
        
        out_ ~= Op.if_;
        out_ ~= cast(ubyte)0x40;
        
        // Allocate new buffer: __arena_alloc(arena, newLength * 4)
        emitArenaPointer(out_);
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        out_ ~= Op.i32_mul;
        uint allocIdx = emitter.getFuncIndex("__arena_alloc");
        out_ ~= Op.call;
        leb128u(out_, allocIdx);
        
        // Store newBuffer at SP-8
        // Save return value to temp local first (i32.store needs [addr, val] order)
        out_ ~= Op.local_set;
        leb128u(out_, tempLocalA);
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 8);
        out_ ~= Op.i32_sub;
        out_ ~= Op.local_get;
        leb128u(out_, tempLocalA);
        // Stack: [SP-8, newBuffer]
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);

        // Copy loop: for i = 0 to oldLength-1
        // Init counter at SP-12
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 12);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_const;
        leb128s(out_, 0);
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        out_ ~= Op.block;
        out_ ~= cast(ubyte)0x40;
        out_ ~= Op.loop;
        out_ ~= cast(ubyte)0x40;
        
        // if (i >= oldLength) break
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 12);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + sliceLayout.lengthOffset);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        out_ ~= Op.i32_ge_u;
        out_ ~= Op.br_if;
        leb128u(out_, 1);
        
        // newBuffer[i] = oldPtr[i]
        // dest addr
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 8);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 12);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;
        
        // src value
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 12);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        // i++
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 12);
        out_ ~= Op.i32_sub;
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 12);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_const;
        leb128s(out_, 1);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        out_ ~= Op.br;
        leb128u(out_, 0);
        out_ ~= Op.end;
        out_ ~= Op.end;
        
        // Update ptr = newBuffer
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr);
        out_ ~= Op.i32_add;
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 8);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        // Update capacity = newLength
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + sliceLayout.capacityOffset);
        out_ ~= Op.i32_add;
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        out_ ~= Op.end;  // end if (need reserve)
        
        // Zero-init from oldLength to newLength if growing
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + sliceLayout.lengthOffset);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        out_ ~= Op.i32_lt_u;  // oldLength < newLength
        
        out_ ~= Op.if_;
        out_ ~= cast(ubyte)0x40;
        
        // Init counter = oldLength
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 12);
        out_ ~= Op.i32_sub;
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + sliceLayout.lengthOffset);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        out_ ~= Op.block;
        out_ ~= cast(ubyte)0x40;
        out_ ~= Op.loop;
        out_ ~= cast(ubyte)0x40;
        
        // if (i >= newLength) break
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 12);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_ge_u;
        out_ ~= Op.br_if;
        leb128u(out_, 1);
        
        // ptr[i] = 0
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 12);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_const;
        leb128s(out_, 0);
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        // i++
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 12);
        out_ ~= Op.i32_sub;
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 12);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_const;
        leb128s(out_, 1);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        out_ ~= Op.br;
        leb128u(out_, 0);
        out_ ~= Op.end;
        out_ ~= Op.end;
        out_ ~= Op.end;  // end if (need zero init)
        
        // Update length = newLength
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + sliceLayout.lengthOffset);
        out_ ~= Op.i32_add;
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        // Leave newLength on stack for expression result
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
    }
    
    //==========================================================================
    // Helpers
    //==========================================================================
    
    bool expressionHasValue(Expression expr) {
        // Most expressions produce values
        if (auto call = cast(CallExpression)expr) {
            // Check if function returns void
            auto ident = cast(IdentifierExpression)call.function_;
            if (ident) {
                // Special case: __writeln is lowered to typed calls, returns void
                if (ident.name == "__writeln") {
                    return false;
                }
                
                // Check local functions
                if (auto idx = ident.name in emitter.funcIndex) {
                    auto f = emitter.functions[*idx];
                    auto sig = emitter.types[f.typeIndex];
                    return sig.results.length > 0;
                }
                // Check imported functions
                if (auto idx = ident.name in emitter.importIndex) {
                    auto imp = emitter.imports[*idx];
                    auto sig = emitter.types[imp.typeIndex];
                    return sig.results.length > 0;
                }
            }
            
            // Check for method calls (obj.method())
            if (auto memberExpr = cast(MemberExpression)call.function_) {
                auto objIdent = cast(IdentifierExpression)memberExpr.object;
                if (objIdent) {
                    // __ctfe_runtime: alloc/remaining return i32, push/pop are void
                    if (objIdent.name == "__ctfe_runtime") {
                        return memberExpr.memberName == "alloc"
                            || memberExpr.memberName == "remaining";
                    }

                    // Check unified locals/params
                    StructDecl structDecl = null;
                    auto objInfo = resolveVar(objIdent.resolvedLocalId, objIdent.name);
                    if (objInfo) {
                        if (objInfo.isSlice && memberExpr.memberName == "reserve")
                            return false;  // reserve() returns void
                        if (objInfo.isStruct)
                            structDecl = objInfo.structDecl;
                    }
                    
                    if (structDecl) {
                        // Find the method
                        foreach (member; structDecl.members) {
                            if (auto funcDecl = cast(FunctionDecl)member) {
                                if (funcDecl.name == memberExpr.memberName && funcDecl.isMethod) {
                                    // Check if method returns void
                                    return !isVoidType(funcDecl.returnType);
                                }
                            }
                        }
                    }
                }
            }
            
            return true;  // Assume has value if unknown
        }
        return true;  // Most expressions have values
    }
    
    private bool isVoidType(Type t) {
        t = t.resolve();
        if (auto basic = cast(BasicType)t) {
            return basic.kind == BasicType.Kind.Void;
        }
        return false;
    }
}
