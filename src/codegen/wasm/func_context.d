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
import codegen.target : WasmSliceLayout, WasmFatPointerLayout, WasmVtablePacking;
import ast.nodes;
import ast.statements;
import ast.expressions;
import semantic.symbol_table;

import std.array : Appender;
import std.algorithm : map, canFind;
import std.conv : to;
import std.format : format;

class FuncContext {
    BinaryEmitter emitter;
    FuncInfo func;

    // Local variables (parameters + locals)
    ValType[] localTypes;
    uint[uint] localIdToWasmIdx;  // uniqueLocalId -> WASM local index
    uint[string] localIndex;       // name -> WASM local index (legacy, for struct/slice lookups)
    uint paramCount;

    /// Discriminant for variable/parameter types in locals/params maps.
    /// Used with `final switch` at multi-way dispatch points to ensure
    /// exhaustive handling — adding a new variant produces compile errors
    /// at every unhandled site.
    enum VarKind {
        scalar,      // Should never appear in WASM locals/params maps
        struct_,
        class_,
        interface_,
        slice,
        staticArray,
    }

    /// Unified info for all shadow-stack local variables
    struct LocalVarInfo {
        VarKind kind;
        uint frameOffset;      // Shadow stack offset from FP
        Type type;             // The D type

        // Tagged payload — at most one is non-null
        StructDecl structDecl;
        ClassDecl classDecl;
        InterfaceDecl ifaceDecl;

        // For slices
        uint dataOffset;
        uint dataSize;
        Type elementType;      // Slice/static-array element type

        // For static arrays
        uint elementCount;
        uint elementSize;

        bool isStruct() const { return kind == VarKind.struct_; }
        bool isClass() const { return kind == VarKind.class_; }
        bool isInterface() const { return kind == VarKind.interface_; }
        bool isSlice() const { return kind == VarKind.slice; }
        bool isStaticArray() const { return kind == VarKind.staticArray; }
    }
    LocalVarInfo[string] locals;

    /// Unified info for all aggregate parameters
    struct ParamVarInfo {
        VarKind kind;
        uint localIndex;       // WASM local index
        uint itableLocalIndex; // Only for interface params (0 otherwise)
        Type type;

        StructDecl structDecl;
        ClassDecl classDecl;
        InterfaceDecl ifaceDecl;
        Type elementType;      // For slice/static-array params

        // For static array params
        uint elementCount;
        uint elementSize;

        bool isStruct() const { return kind == VarKind.struct_; }
        bool isClass() const { return kind == VarKind.class_; }
        bool isInterface() const { return kind == VarKind.interface_; }
        bool isSlice() const { return kind == VarKind.slice; }
        bool isStaticArray() const { return kind == VarKind.staticArray; }
    }
    ParamVarInfo[string] params;

    uint frameSize = 0;        // Total size of struct/slice locals on shadow stack
    uint savedSpLocal;         // Local index to store saved SP (for epilogue restore)
    uint fpLocal;              // Local index for frame pointer (stable, never changes)
    
    // Block depth for br instructions
    uint blockDepth = 0;
    
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
            ParamVarInfo pvi;
            pvi.kind = VarKind.struct_;
            pvi.localIndex = 0;
            pvi.structDecl = f.structParent;
            params["this"] = pvi;
        }

        // Same for class methods
        if (f.classParent !is null) {
            localTypes ~= ValType.i32;  // 'this' is a pointer (i32)
            thisLocalIndex = 0;
            localOffset = 1;

            // Register 'this' as a class param so this.x works
            ParamVarInfo pvi;
            pvi.kind = VarKind.class_;
            pvi.localIndex = 0;
            pvi.classDecl = f.classParent;
            params["this"] = pvi;
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
                    returnValueSize = WasmSliceLayout.sizeof;  // Slice struct
                }
            } else if (auto sd = f.decl.returnType.asStruct()) {
                returnValueSize = cast(uint)sd.structSize;
            } else {
                returnValueSize = cast(uint)f.decl.returnType.size();
            }
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
            
            localIndex[p.name] = wasmLocalIdx;  // Legacy name-based lookup
            if (p.uniqueLocalId != uint.max) {
                localIdToWasmIdx[p.uniqueLocalId] = wasmLocalIdx;
            }
            
            if (isInterfaceParam) {
                // Interface: fat pointer = 2 i32 locals (obj_ptr, itable_ptr)
                localTypes ~= ValType.i32;
                localTypes ~= ValType.i32;
                
                ParamVarInfo pvi;
                pvi.kind = VarKind.interface_;
                pvi.localIndex = wasmLocalIdx;
                pvi.itableLocalIndex = wasmLocalIdx + 1;
                pvi.type = p.type;
                pvi.ifaceDecl = ifaceDecl;
                params[p.name] = pvi;

                wasmLocalIdx += 2;
            } else {
                auto vt = e.dTypeToValType(p.type);
                localTypes ~= vt;
                
                // Track struct/class/slice/static-array parameters
                ParamVarInfo pvi;
                pvi.localIndex = wasmLocalIdx;
                pvi.type = p.type;

                if (auto structDecl = p.type.asStruct()) {
                    pvi.kind = VarKind.struct_;
                    pvi.structDecl = structDecl;
                } else if (auto classDecl = p.type.asClass()) {
                    pvi.kind = VarKind.class_;
                    pvi.classDecl = classDecl;
                } else if (auto arrayType = cast(ArrayType)p.type) {
                    if (arrayType.arraySize !is null) {
                        // Static array param — passed as i32 pointer
                        pvi.kind = VarKind.staticArray;
                        pvi.elementType = arrayType.elementType;
                        pvi.elementCount = evaluateStaticArraySize(arrayType.arraySize);
                        size_t elemSize = arrayType.elementType.size();
                        if (elemSize == 0) elemSize = 4;
                        pvi.elementSize = cast(uint)elemSize;
                    } else {
                        // Dynamic array (slice)
                        pvi.kind = VarKind.slice;
                        pvi.elementType = arrayType.elementType;
                    }
                }

                if (pvi.kind != VarKind.scalar)
                    params[p.name] = pvi;
                
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

                    LocalVarInfo lvi;
                    lvi.kind = VarKind.struct_;
                    lvi.frameOffset = frameSize;
                    lvi.type = varDecl.type;
                    lvi.structDecl = structDecl;
                    locals[varDecl.name] = lvi;

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

                    LocalVarInfo lvi;
                    lvi.kind = VarKind.class_;
                    lvi.frameOffset = frameSize;
                    lvi.type = varDecl.type;
                    lvi.classDecl = classDecl;
                    locals[varDecl.name] = lvi;

                    frameSize += cast(uint)classDecl.classSize;
                    return;
                }

                // Interface local - allocate fat pointer on shadow stack (8 bytes)
                if (auto ifaceDecl = userType.asInterface()) {
                    frameSize = (frameSize + 3) & ~3;  // Align to 4 bytes

                    LocalVarInfo lvi;
                    lvi.kind = VarKind.interface_;
                    lvi.frameOffset = frameSize;
                    lvi.type = varDecl.type;
                    lvi.ifaceDecl = ifaceDecl;
                    locals[varDecl.name] = lvi;

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
                    size_t elemSize = arrayType.elementType.size();
                    if (elemSize == 0) elemSize = 4;  // Default to 4 for i32
                    
                    LocalVarInfo lvi;
                    lvi.kind = VarKind.staticArray;
                    lvi.frameOffset = frameSize;
                    lvi.type = varDecl.type;
                    lvi.elementType = arrayType.elementType;
                    lvi.elementCount = elemCount;
                    lvi.elementSize = cast(uint)elemSize;
                    locals[varDecl.name] = lvi;

                    frameSize += elemCount * cast(uint)elemSize;
                    return;
                }
                
                // Dynamic array/slice - allocate WasmSliceLayout.sizeof bytes for slice struct (ptr, length, capacity)
                frameSize = (frameSize + 3) & ~3;  // Align to 4 bytes
                
                // Enable array support for __alloc, etc.
                emitter.needsArraySupport = true;
                
                LocalVarInfo lvi;
                lvi.kind = VarKind.slice;
                lvi.frameOffset = frameSize;
                lvi.type = varDecl.type;
                lvi.elementType = arrayType.elementType;

                // Slice struct is WasmSliceLayout.sizeof bytes (ptr: i32, length: i32, capacity: i32)
                frameSize += WasmSliceLayout.sizeof;

                // If initialized with array literal, also allocate space for data
                if (auto arrayLit = cast(ArrayLiteralExpression)varDecl.initializer) {
                    frameSize = (frameSize + 3) & ~3;  // Align data
                    lvi.dataOffset = frameSize;

                    // Calculate data size based on element type and count
                    size_t elemSize = arrayType.elementType.size();
                    if (elemSize == 0) elemSize = 4;  // Default to 4 for i32
                    lvi.dataSize = cast(uint)(elemSize * arrayLit.elements.length);

                    frameSize += lvi.dataSize;
                }

                locals[varDecl.name] = lvi;
                return;
            }
            
            // Regular local - add to WASM locals
            auto vt = emitter.dTypeToValType(varDecl.type);
            uint wasmIdx = cast(uint)localTypes.length;
            localIndex[varDecl.name] = wasmIdx;  // Legacy name-based lookup
            if (varDecl.uniqueLocalId != uint.max) {
                localIdToWasmIdx[varDecl.uniqueLocalId] = wasmIdx;
            }
            localTypes ~= vt;
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
            if (auto info = varDecl.name in locals) {
                final switch (info.kind) {
                    case VarKind.struct_:     emitStructVarDecl(out_, varDecl); break;
                    case VarKind.class_:      emitClassVarDecl(out_, varDecl); break;
                    case VarKind.interface_:  emitInterfaceVarDecl(out_, varDecl); break;
                    case VarKind.staticArray: emitStaticArrayVarDecl(out_, varDecl); break;
                    case VarKind.slice:       emitSliceVarDecl(out_, varDecl); break;
                    case VarKind.scalar:      assert(0, "scalar in locals map");
                }
            } else {
                emitVarDecl(out_, varDecl);
            }
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
            if (auto info = ident.name in locals) {
                final switch (info.kind) {
                    case VarKind.struct_:
                    case VarKind.staticArray:
                        emitMemoryCopy(out_, resultPtrLocalIdx, info.frameOffset, returnValueSize);
                        return;
                    case VarKind.class_:
                    case VarKind.interface_:
                    case VarKind.slice:
                        break;  // fall through to generic path
                    case VarKind.scalar:
                        assert(0, "scalar in locals map");
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
        return false;
    }
    
    void emitWhile(ref Appender!(ubyte[]) out_, WhileStatement stmt) {
        // block (for break)
        out_ ~= Op.block;
        out_ ~= cast(ubyte)BlockType.void_;
        blockDepth++;
        
        // loop
        out_ ~= Op.loop;
        out_ ~= cast(ubyte)BlockType.void_;
        blockDepth++;
        
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
        
        // Body
        emitStatement(out_, stmt.body_);
        
        // Update
        if (stmt.update) {
            emitExpression(out_, stmt.update);
            if (expressionHasValue(stmt.update)) {
                out_ ~= Op.drop;
            }
        }
        
        // Continue
        out_ ~= Op.br;
        leb128u(out_, 0);
        
        blockDepth--;
        out_ ~= Op.end;  // End loop
        
        blockDepth--;
        out_ ~= Op.end;  // End block
    }
    
    void emitVarDecl(ref Appender!(ubyte[]) out_, VariableDeclarationStatement stmt) {
        // Use uniqueLocalId if available, fall back to name lookup
        uint idx;
        if (stmt.uniqueLocalId != uint.max && stmt.uniqueLocalId in localIdToWasmIdx) {
            idx = localIdToWasmIdx[stmt.uniqueLocalId];
        } else {
            idx = localIndex[stmt.name];
        }
        
        if (stmt.initializer) {
            emitExpression(out_, stmt.initializer);
        } else {
            // Default init to 0
            out_ ~= Op.i32_const;
            leb128s(out_, 0);
        }
        
        out_ ~= Op.local_set;
        leb128u(out_, idx);
    }
    
    /**
     * Emit struct local variable declaration - stores fields to shadow stack
     */
    void emitStructVarDecl(ref Appender!(ubyte[]) out_, VariableDeclarationStatement stmt) {
        auto infoPtr = stmt.name in locals;
        assert(infoPtr !is null && infoPtr.isStruct, "Expected struct local: " ~ stmt.name);
        auto info = *infoPtr;
        auto structDecl = info.structDecl;
        
        if (!stmt.initializer) {
            // Zero-initialize the struct
            foreach (field; structDecl.fields) {
                // Address: FP + frameOffset + fieldOffset
                out_ ~= Op.local_get;
                leb128u(out_, fpLocal);
                out_ ~= Op.i32_const;
                leb128s(out_, info.frameOffset + cast(int)field.offset);
                out_ ~= Op.i32_add;
                
                // Value: 0
                out_ ~= Op.i32_const;
                leb128s(out_, 0);
                
                // Store
                out_ ~= Op.i32_store;
                out_ ~= cast(ubyte)0x02;  // alignment log2(4)
                leb128u(out_, 0);          // offset
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
        
        // Struct copy: Point b = a (copy from another struct variable)
        if (auto identExpr = cast(IdentifierExpression)stmt.initializer) {
            // Check if source is a local struct
            if (auto srcInfo = identExpr.name in locals) if (srcInfo.isStruct) {
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
        auto infoPtr = stmt.name in locals;
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
            if (auto srcInfo = identExpr.name in locals) if (srcInfo.isClass) {
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
        auto infoPtr = stmt.name in locals;
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
            leb128s(out_, info.frameOffset + WasmSliceLayout.LENGTH_OFFSET);
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
            if (auto lvi = identExpr.name in locals) {
                if (lvi.isClass) {
                    srcClass = lvi.classDecl;

                    // Store obj_ptr: fat_ptr.obj_ptr = FP + lvi.frameOffset
                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.frameOffset);  // dest
                    out_ ~= Op.i32_add;

                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, lvi.frameOffset);  // src obj addr
                    out_ ~= Op.i32_add;

                    out_ ~= Op.i32_store;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                }
            } else if (auto pvi = identExpr.name in params) {
                if (pvi.isClass) {
                    srcClass = pvi.classDecl;

                    // Store obj_ptr: fat_ptr.obj_ptr = param value
                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.frameOffset);
                    out_ ~= Op.i32_add;

                    out_ ~= Op.local_get;
                    leb128u(out_, pvi.localIndex);

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
                    leb128s(out_, info.frameOffset + WasmSliceLayout.LENGTH_OFFSET);
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
                    
                    if (auto srcInfo = identExpr.name in locals) {
                        if (srcInfo.isClass) {
                            out_ ~= Op.local_get;
                            leb128u(out_, fpLocal);
                            out_ ~= Op.i32_const;
                            leb128s(out_, srcInfo.frameOffset);
                            out_ ~= Op.i32_add;
                        }
                    } else if (auto srcInfo = identExpr.name in params) {
                        if (srcInfo.isClass) {
                            out_ ~= Op.local_get;
                            leb128u(out_, srcInfo.localIndex);
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
                    leb128s(out_, info.frameOffset + WasmSliceLayout.LENGTH_OFFSET);
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
     * Slice struct layout: { ptr: i32, length: i32, capacity: i32 } = WasmSliceLayout.sizeof bytes
     */
    void emitSliceVarDecl(ref Appender!(ubyte[]) out_, VariableDeclarationStatement stmt) {
        auto infoPtr = stmt.name in locals;
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
                out_ ~= Op.i32_store;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
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
            leb128s(out_, info.frameOffset + WasmSliceLayout.LENGTH_OFFSET);  // slice.length offset = 4
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
            leb128s(out_, info.frameOffset + WasmSliceLayout.CAPACITY_OFFSET);  // slice.capacity offset = 8
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
                leb128s(out_, info.frameOffset + WasmSliceLayout.LENGTH_OFFSET);  // slice.length offset = 4
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
                leb128s(out_, info.frameOffset + WasmSliceLayout.CAPACITY_OFFSET);  // slice.capacity offset = 8
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
            leb128s(out_, info.frameOffset + WasmSliceLayout.LENGTH_OFFSET);
            out_ ~= Op.i32_add;
            out_ ~= Op.i32_const;
            leb128s(out_, len);
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, info.frameOffset + WasmSliceLayout.CAPACITY_OFFSET);
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
            
            auto sourceInfo = sourceIdent.name in locals;
            if (sourceInfo && !sourceInfo.isSlice) sourceInfo = null;
            if (!sourceInfo) {
                throw new EmitError("Can only slice local arrays for now");
            }
            
            // Calculate ptr = source.ptr + start * elemSize
            // Store at FP + frameOffset (slice.ptr)
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, info.frameOffset);
            out_ ~= Op.i32_add;
            
            // Load source.ptr
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, sourceInfo.frameOffset);  // source.ptr at offset 0
            out_ ~= Op.i32_add;
            out_ ~= Op.i32_load;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            
            // Add start * 4
            emitExpression(out_, sliceExpr.start);
            out_ ~= Op.i32_const;
            leb128s(out_, 4);  // sizeof(int)
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
            leb128s(out_, info.frameOffset + WasmSliceLayout.LENGTH_OFFSET);
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
            leb128s(out_, info.frameOffset + WasmSliceLayout.CAPACITY_OFFSET);
            out_ ~= Op.i32_add;
            
            emitExpression(out_, sliceExpr.end);
            emitExpression(out_, sliceExpr.start);
            out_ ~= Op.i32_sub;
            
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            
            return;
        }
        
        throw new EmitError("Unsupported slice initializer", stmt.initializer.toString());
    }
    
    /**
     * Emit static array local variable declaration
     * Static arrays are stored directly on the shadow stack (no slice struct)
     */
    void emitStaticArrayVarDecl(ref Appender!(ubyte[]) out_, VariableDeclarationStatement stmt) {
        auto infoPtr = stmt.name in locals;
        assert(infoPtr !is null && infoPtr.isStaticArray, "Expected static array local: " ~ stmt.name);
        auto info = *infoPtr;
        
        // No initializer - leave as zero-initialized (shadow stack is zeroed)
        if (!stmt.initializer) {
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
            // Slice expressions as standalone expressions are complex
            // For now, we only support them as initializers (handled in emitSliceVarDecl)
            throw new EmitError("Slice expressions only supported as initializers for now");
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
        // Get the array identifier
        auto arrayIdent = cast(IdentifierExpression)expr.array;
        if (!arrayIdent) {
            throw new EmitError("Complex array indexing not yet supported");
        }
        
        // Check if it's a local on the shadow stack
        if (auto info = arrayIdent.name in locals) {
            final switch (info.kind) {
                case VarKind.staticArray:
                    // Static array: data is directly on shadow stack at frameOffset
                    // Address = FP + frameOffset + index * elemSize
                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.frameOffset);
                    out_ ~= Op.i32_add;

                    // Add index * elemSize
                    emitExpression(out_, expr.index);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.elementSize);
                    out_ ~= Op.i32_mul;
                    out_ ~= Op.i32_add;

                    // Load the element
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    return;

                case VarKind.slice:
                    // Load ptr from slice struct (offset 0)
                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.frameOffset);  // ptr is at offset 0
                    out_ ~= Op.i32_add;
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);

                    // Calculate address: ptr + index * elemSize
                    emitExpression(out_, expr.index);
                    out_ ~= Op.i32_const;
                    leb128s(out_, 4);  // sizeof(int) = 4
                    out_ ~= Op.i32_mul;
                    out_ ~= Op.i32_add;

                    // Load the element
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    return;

                case VarKind.struct_:
                case VarKind.class_:
                case VarKind.interface_:
                    assert(0, "Cannot index " ~ arrayIdent.name ~ " (not an array type)");
                case VarKind.scalar:
                    assert(0, "scalar in locals map");
            }
        }

        // Check if it's an array/slice parameter
        if (auto info = arrayIdent.name in params) {
            final switch (info.kind) {
                case VarKind.staticArray:
                    // Static array param: i32 pointer to array data
                    // Address = param_ptr + index * elemSize
                    out_ ~= Op.local_get;
                    leb128u(out_, info.localIndex);

                    emitExpression(out_, expr.index);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.elementSize);
                    out_ ~= Op.i32_mul;
                    out_ ~= Op.i32_add;

                    // Load the element
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    return;

                case VarKind.slice:
                    // The parameter contains a pointer to the slice struct
                    // Load ptr from slice struct (offset 0)
                    out_ ~= Op.local_get;
                    leb128u(out_, info.localIndex);
                    out_ ~= Op.i32_load;  // Load ptr field (at offset 0 of slice struct)
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);

                    // Calculate address: ptr + index * elemSize
                    emitExpression(out_, expr.index);
                    out_ ~= Op.i32_const;
                    leb128s(out_, 4);  // sizeof(int) = 4
                    out_ ~= Op.i32_mul;
                    out_ ~= Op.i32_add;

                    // Load the element
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    return;

                case VarKind.struct_:
                case VarKind.class_:
                case VarKind.interface_:
                    assert(0, "Cannot index " ~ arrayIdent.name ~ " param (not an array type)");
                case VarKind.scalar:
                    assert(0, "scalar in params map");
            }
        }
        
        // Check if it's a manifest constant array (import(), etc.)
        auto symbol = emitter.symbolTable.lookupSymbol(arrayIdent.name);
        if (symbol && symbol.kind == SymbolKind.Variable && symbol.isConstant) {
            if (auto manifest = cast(ManifestConstantDecl)symbol.declaration) {
                if (manifest.ctfeComplete && manifest.isArrayType) {
                    uint structAddr = emitter.registerManifestArray(manifest);
                    
                    // Determine element size based on inferred type
                    uint elemSize = manifest.ctfeElementSize;
                    if (elemSize == 0) elemSize = 4;  // default to i32
                    
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
                    if (elemSize == 1) {
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
        // Get the array identifier
        auto arrayIdent = cast(IdentifierExpression)indexExpr.array;
        if (!arrayIdent) {
            throw new EmitError("Complex array index assignment not yet supported");
        }
        
        // Check if it's a local on the shadow stack
        if (auto info = arrayIdent.name in locals) {
            final switch (info.kind) {
                case VarKind.staticArray:
                    // Static array: direct address on shadow stack
                    // Address = FP + frameOffset + index * elemSize
                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.frameOffset);
                    out_ ~= Op.i32_add;

                    // Add index * elemSize
                    emitExpression(out_, indexExpr.index);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.elementSize);
                    out_ ~= Op.i32_mul;
                    out_ ~= Op.i32_add;

                    // Emit value
                    emitExpression(out_, value);

                    // Store the element
                    out_ ~= Op.i32_store;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);

                    // Assignment is an expression - emit value again for result
                    emitExpression(out_, value);
                    return;

                case VarKind.slice:
                    // Load ptr from slice struct (offset 0)
                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.frameOffset);  // ptr is at offset 0
                    out_ ~= Op.i32_add;
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);

                    // Calculate address: ptr + index * elemSize
                    emitExpression(out_, indexExpr.index);
                    out_ ~= Op.i32_const;
                    leb128s(out_, 4);  // sizeof(int) = 4
                    out_ ~= Op.i32_mul;
                    out_ ~= Op.i32_add;

                    // Emit value
                    emitExpression(out_, value);

                    // Store the element
                    out_ ~= Op.i32_store;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);

                    // Assignment is an expression - emit value again for result
                    emitExpression(out_, value);
                    return;

                case VarKind.struct_:
                case VarKind.class_:
                case VarKind.interface_:
                    assert(0, "Cannot index-assign " ~ arrayIdent.name ~ " (not an array type)");
                case VarKind.scalar:
                    assert(0, "scalar in locals map");
            }
        }

        // Check if it's an array/slice parameter
        if (auto info = arrayIdent.name in params) {
            final switch (info.kind) {
                case VarKind.staticArray:
                    // Static array param: i32 pointer to array data
                    // Address = param_ptr + index * elemSize
                    out_ ~= Op.local_get;
                    leb128u(out_, info.localIndex);

                    emitExpression(out_, indexExpr.index);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.elementSize);
                    out_ ~= Op.i32_mul;
                    out_ ~= Op.i32_add;

                    // Emit value
                    emitExpression(out_, value);

                    // Store the element
                    out_ ~= Op.i32_store;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);

                    // Assignment is an expression - emit value again for result
                    emitExpression(out_, value);
                    return;

                case VarKind.slice:
                    // The parameter contains a pointer to the slice struct
                    // Load ptr from slice struct (offset 0)
                    out_ ~= Op.local_get;
                    leb128u(out_, info.localIndex);
                    out_ ~= Op.i32_load;  // Load ptr field (at offset 0 of slice struct)
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);

                    // Calculate address: ptr + index * elemSize
                    emitExpression(out_, indexExpr.index);
                    out_ ~= Op.i32_const;
                    leb128s(out_, 4);  // sizeof(int) = 4
                    out_ ~= Op.i32_mul;
                    out_ ~= Op.i32_add;

                    // Emit value
                    emitExpression(out_, value);

                    // Store the element
                    out_ ~= Op.i32_store;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);

                    // Assignment is an expression - emit value again for result
                    emitExpression(out_, value);
                    return;

                case VarKind.struct_:
                case VarKind.class_:
                case VarKind.interface_:
                    assert(0, "Cannot index-assign " ~ arrayIdent.name ~ " param (not an array type)");
                case VarKind.scalar:
                    assert(0, "scalar in params map");
            }
        }

        throw new EmitError("Unsupported array index assignment on " ~ arrayIdent.name);
    }
    
    /**
     * Emit a built-in method call on a slice (reserve, etc.)
     */
    void emitSliceBuiltinMethod(ref Appender!(ubyte[]) out_, string sliceName,
                                 LocalVarInfo* sliceInfo, string methodName, Expression[] args) {
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
                          LocalVarInfo* sliceInfo, Expression[] args) {
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
        leb128s(out_, sliceAddr + WasmSliceLayout.CAPACITY_OFFSET);  // capacity offset
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
        
        // Allocate new buffer: __alloc(newCapacity * 4)
        // First, re-evaluate newCapacity (we consumed it in comparison)
        emitExpression(out_, args[0]);
        out_ ~= Op.i32_const;
        leb128s(out_, 4);  // sizeof(int)
        out_ ~= Op.i32_mul;
        
        // Call __alloc
        uint allocIdx = emitter.getFuncIndex("__alloc");
        out_ ~= Op.call;
        leb128u(out_, allocIdx);
        // Stack: [newBuffer]
        
        // Store newBuffer in a temp location (use SP - 4)
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        out_ ~= Op.i32_sub;
        // Stack: [newBuffer, tempAddr]
        // Swap and store
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
        leb128s(out_, sliceAddr + WasmSliceLayout.LENGTH_OFFSET);  // length offset
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
        leb128s(out_, sliceAddr + WasmSliceLayout.CAPACITY_OFFSET);  // capacity offset
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
                         LocalVarInfo* sliceInfo, Expression value) {
        int sliceAddr = sliceInfo.frameOffset;
        
        // Store value at SP-4 (we need it later)
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        out_ ~= Op.i32_sub;
        emitExpression(out_, value);
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        // Check if length >= capacity
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + WasmSliceLayout.LENGTH_OFFSET);  // length
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + WasmSliceLayout.CAPACITY_OFFSET);  // capacity
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        out_ ~= Op.i32_ge_u;  // length >= capacity
        
        out_ ~= Op.if_;
        out_ ~= cast(ubyte)0x40;
        
        // Need to grow: newCapacity = max(capacity * 2, 4)
        // Store newCapacity at SP-8
        // First push the destination address
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 8);
        out_ ~= Op.i32_sub;
        
        // Calculate capacity * 2
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + WasmSliceLayout.CAPACITY_OFFSET);
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
        leb128s(out_, sliceAddr + WasmSliceLayout.CAPACITY_OFFSET);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_const;
        leb128s(out_, 2);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        out_ ~= Op.i32_lt_u;
        out_ ~= Op.select;  // picks 4 if capacity*2 < 4, else capacity*2
        
        // Now stack has [SP-8, newCapacity], store
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        // Allocate new buffer
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 8);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        out_ ~= Op.i32_mul;
        uint allocIdx = emitter.getFuncIndex("__alloc");
        out_ ~= Op.call;
        leb128u(out_, allocIdx);
        
        // Store newBuffer at SP-12
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 12);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_store;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        // Copy loop
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 16);
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
        leb128s(out_, 16);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + WasmSliceLayout.LENGTH_OFFSET);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_ge_u;
        out_ ~= Op.br_if;
        leb128u(out_, 1);
        
        // newBuffer[i] = oldPtr[i]
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
        leb128s(out_, 16);
        out_ ~= Op.i32_sub;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
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
        leb128s(out_, 16);
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
        leb128s(out_, 16);
        out_ ~= Op.i32_sub;
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 16);
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
        leb128s(out_, 12);
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
        leb128s(out_, sliceAddr + WasmSliceLayout.CAPACITY_OFFSET);
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
        
        out_ ~= Op.end;  // end if (need grow)
        
        // Store value at ptr[length]
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
        leb128s(out_, sliceAddr + WasmSliceLayout.LENGTH_OFFSET);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        out_ ~= Op.i32_const;
        leb128s(out_, 4);
        out_ ~= Op.i32_mul;
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
        
        // Increment length
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + WasmSliceLayout.LENGTH_OFFSET);
        out_ ~= Op.i32_add;
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, sliceAddr + WasmSliceLayout.LENGTH_OFFSET);
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
        leb128s(out_, sliceAddr + WasmSliceLayout.LENGTH_OFFSET);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
    }
    
    void emitCast(ref Appender!(ubyte[]) out_, CastExpression expr) {
        // Check for class→interface cast (annotated by type checker)
        if (expr.sourceClassDecl && expr.targetInterfaceDecl) {
            // Emit fat pointer: (obj_ptr, itable_ptr)
            emitClassToInterfaceCast(out_, expr);
            return;
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
            if (auto lInfo = identExpr.name in locals) {
                if (lInfo.isClass) {
                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, lInfo.frameOffset);
                    out_ ~= Op.i32_add;
                } else {
                    throw new EmitError("Variable is not a class in cast: " ~ identExpr.name);
                }
            } else if (auto pInfo = identExpr.name in params) {
                if (pInfo.isClass) {
                    out_ ~= Op.local_get;
                    leb128u(out_, pInfo.localIndex);
                } else {
                    throw new EmitError("Parameter is not a class in cast: " ~ identExpr.name);
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
                    if (manifest.ctfeComplete && manifest.isArrayType) {
                        // Register the array data and get struct address
                        uint structAddr = emitter.registerManifestArray(manifest);
                        
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
            
            // Check locals (struct, class, slice on shadow stack)
            if (auto info = ident.name in locals) {
                if (info.isStruct || info.isClass) {
                    auto aggr = info.isStruct ? cast(AggregateDecl)info.structDecl
                                              : cast(AggregateDecl)info.classDecl;
                    auto field = aggr.getField(expr.memberName);
                    if (field) {
                        // Load from FP + frameOffset + fieldOffset
                        out_ ~= Op.local_get;
                        leb128u(out_, fpLocal);
                        out_ ~= Op.i32_const;
                        leb128s(out_, info.frameOffset + cast(int)field.offset);
                        out_ ~= Op.i32_add;
                        out_ ~= Op.i32_load;
                        out_ ~= cast(ubyte)0x02;
                        leb128u(out_, 0);
                        return;
                    }
                } else if (info.isSlice) {
                    int fieldOffset;
                    if (expr.memberName == "ptr") fieldOffset = 0;
                    else if (expr.memberName == "length") fieldOffset = 4;
                    else if (expr.memberName == "capacity") fieldOffset = 8;
                    else throw new EmitError("Slice has no field '" ~ expr.memberName ~ "'");

                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.frameOffset + fieldOffset);
                    out_ ~= Op.i32_add;
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    return;
                }
            }

            // Check params (struct, slice)
            if (auto pinfo = ident.name in params) {
                if (pinfo.isStruct) {
                    auto field = pinfo.structDecl.getField(expr.memberName);
                    if (field) {
                        out_ ~= Op.local_get;
                        leb128u(out_, pinfo.localIndex);
                        out_ ~= Op.i32_const;
                        leb128s(out_, cast(int)field.offset);
                        out_ ~= Op.i32_add;
                        out_ ~= Op.i32_load;
                        out_ ~= cast(ubyte)0x02;
                        leb128u(out_, 0);
                        return;
                    }
                } else if (pinfo.isSlice) {
                    int fieldOffset;
                    if (expr.memberName == "ptr") fieldOffset = 0;
                    else if (expr.memberName == "length") fieldOffset = 4;
                    else if (expr.memberName == "capacity") fieldOffset = 8;
                    else throw new EmitError("Slice has no field '" ~ expr.memberName ~ "'");

                    out_ ~= Op.local_get;
                    leb128u(out_, pinfo.localIndex);
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
        }
        
        throw new EmitError("Member access not yet fully implemented", expr.toString());
    }
    
    /**
     * Emit the ADDRESS of a member expression (for nested access).
     * Leaves address on stack, doesn't load the value.
     */
    void emitMemberAddress(ref Appender!(ubyte[]) out_, MemberExpression expr) {
        if (auto ident = cast(IdentifierExpression)expr.object) {
            // Check struct/class locals
            if (auto info = ident.name in locals) {
                if (info.isStruct || info.isClass) {
                    auto aggr = info.isStruct ? cast(AggregateDecl)info.structDecl
                                              : cast(AggregateDecl)info.classDecl;
                    auto field = aggr.getField(expr.memberName);
                    if (field) {
                        out_ ~= Op.local_get;
                        leb128u(out_, fpLocal);
                        out_ ~= Op.i32_const;
                        leb128s(out_, info.frameOffset + cast(int)field.offset);
                        out_ ~= Op.i32_add;
                        return;
                    }
                }
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
     * Get the type of a member expression (for determining nested field offsets).
     */
    Type getMemberExpressionType(MemberExpression expr) {
        Type objType;

        if (auto ident = cast(IdentifierExpression)expr.object) {
            // Check locals then params for struct type
            StructDecl sd;
            if (auto info = ident.name in locals) {
                if (info.isStruct) sd = info.structDecl;
            }
            if (!sd) {
                if (auto pinfo = ident.name in params) {
                    if (pinfo.isStruct) sd = pinfo.structDecl;
                }
            }
            if (sd) {
                objType = new UserType(SourceLocation(), sd.name);
                (cast(UserType)objType).declaration = sd;
            }
        } else if (auto innerMember = cast(MemberExpression)expr.object) {
            objType = getMemberExpressionType(innerMember);
        }
        
        if (auto structDecl = objType.asStruct()) {
            auto field = structDecl.getField(expr.memberName);
            if (field) {
                return field.type;
            }
        }
        
        return null;
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
        // First check if type checker resolved this to a local variable
        if (expr.resolvedLocalId != uint.max) {
            if (auto wasmIdx = expr.resolvedLocalId in localIdToWasmIdx) {
                out_ ~= Op.local_get;
                leb128u(out_, *wasmIdx);
                return;
            }
        }
        
        // Fallback to legacy name-based lookup
        if (auto idx = expr.name in localIndex) {
            out_ ~= Op.local_get;
            leb128u(out_, *idx);
            return;
        }
        
        // For symbol table lookup (constants, globals), do it now
        Symbol symbol = emitter.symbolTable.lookupSymbol(expr.name);
        
        // Check if it's a local on the shadow stack — emit address: FP + frameOffset
        // All entries in locals are on the shadow stack
        if (auto info = expr.name in locals) {
            final switch (info.kind) {
                case VarKind.struct_:
                case VarKind.class_:
                case VarKind.interface_:
                case VarKind.staticArray:
                case VarKind.slice:
                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.frameOffset);
                    out_ ~= Op.i32_add;
                    return;
                case VarKind.scalar:
                    assert(0, "scalar in locals map");
            }
        }

        // In a method, check if it's an implicit field access (field without 'this.')
        if (auto thisInfo = "this" in params) {
            AggregateDecl parent = func.structParent ? cast(AggregateDecl)func.structParent
                                                     : cast(AggregateDecl)func.classParent;
            if (parent) {
                auto field = parent.getField(expr.name);
                if (field) {
                    out_ ~= Op.local_get;
                    leb128u(out_, thisInfo.localIndex);
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
        // Reuse symbol lookup from above (or do fresh lookup if symbol is null)
        if (symbol is null) {
            symbol = emitter.symbolTable.lookupSymbol(expr.name);
        }
        if (symbol && symbol.isConstant) {
            if (auto manifest = cast(ManifestConstantDecl)symbol.declaration) {
                // Trigger lazy evaluation if needed, then emit
                if (manifest.isStringType) {
                    // Ensure it's evaluated (for string, ctfeStringValue is set during eval)
                    if (!manifest.ctfeComplete) {
                        emitter.symbolTable.resolveManifestValue(manifest);
                    }
                    // String constant: register and emit struct pointer
                    uint structAddr = emitter.registerArrayLiteral(manifest.ctfeStringValue);
                    out_ ~= Op.i32_const;
                    leb128s(out_, structAddr);
                } else {
                    // Numeric constant: emit value via lazy resolver
                    out_ ~= Op.i32_const;
                    leb128s(out_, emitter.symbolTable.resolveManifestValue(manifest));
                }
                return;
            }
        }
        
        throw new EmitError("Unknown identifier: " ~ expr.name);
    }
    
    void emitBinary(ref Appender!(ubyte[]) out_, BinaryExpression expr) {
        // Handle string concatenation specially
        if (expr.operator == BinaryExpression.Operator.Concat) {
            emitArrayConcat(out_, expr);
            return;
        }
        
        // Emit operands
        emitExpression(out_, expr.left);
        emitExpression(out_, expr.right);
        
        // Emit operator (assuming i32 for now)
        Op op;
        final switch (expr.operator) {
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
                // a && b -> a ? b : 0
                // For now, simple: both operands, then and
                op = Op.i32_and;
                break;
            case BinaryExpression.Operator.LogicalOr:
                op = Op.i32_or;
                break;
            case BinaryExpression.Operator.BitwiseAnd: op = Op.i32_and; break;
            case BinaryExpression.Operator.BitwiseOr: op = Op.i32_or; break;
            case BinaryExpression.Operator.BitwiseXor: op = Op.i32_xor; break;
            case BinaryExpression.Operator.ShiftLeft: op = Op.i32_shl; break;
            case BinaryExpression.Operator.ShiftRight: op = Op.i32_shr_s; break;
            case BinaryExpression.Operator.UnsignedShiftRight: op = Op.i32_shr_u; break;
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
        
        auto idx = localIndex[ident.name];
        
        if (expr.isPostfix) {
            // Return old value, then modify
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
            // Modify, then return new value
            out_ ~= Op.local_get;
            leb128u(out_, idx);
            out_ ~= Op.i32_const;
            leb128s(out_, 1);
            out_ ~= (inc ? Op.i32_add : Op.i32_sub);
            out_ ~= Op.local_tee;
            leb128u(out_, idx);
        }
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
        
        // Get callee's parameter types for interface conversion detection
        FunctionDecl calleeDecl = null;
        if (auto funcInfo = ident.name in emitter.funcIndex) {
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

        // Emit arguments (copy structs for pass-by-value semantics)
        uint totalCopySize = 0;
        foreach (argIdx, arg; expr.arguments) {
            // Check if argument is a struct local that needs copying
            if (auto argIdent = cast(IdentifierExpression)arg) {
                if (auto localInfo = argIdent.name in locals) if (localInfo.isStruct) {
                    // Struct local - copy to temp, pass temp address
                    auto structDecl = localInfo.structDecl;
                    uint structSize = cast(uint)structDecl.structSize;
                    
                    // Allocate temp: SP = SP - structSize
                    out_ ~= Op.global_get;
                    leb128u(out_, emitter.spGlobal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, structSize);
                    out_ ~= Op.i32_sub;
                    out_ ~= Op.global_set;
                    leb128u(out_, emitter.spGlobal);
                    
                    // Copy from FP+offset to SP
                    foreach (field; structDecl.fields) {
                        // Dest: SP + fieldOffset
                        out_ ~= Op.global_get;
                        leb128u(out_, emitter.spGlobal);
                        if (field.offset > 0) {
                            out_ ~= Op.i32_const;
                            leb128s(out_, cast(int)field.offset);
                            out_ ~= Op.i32_add;
                        }
                        
                        // Src: FP + srcOffset + fieldOffset
                        out_ ~= Op.local_get;
                        leb128u(out_, fpLocal);
                        out_ ~= Op.i32_const;
                        leb128s(out_, localInfo.frameOffset + cast(int)field.offset);
                        out_ ~= Op.i32_add;
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
                
                if (auto paramInfo = argIdent.name in params) if (paramInfo.isStruct) {
                    // Struct param - already a pointer, copy from it
                    auto structDecl = paramInfo.structDecl;
                    uint structSize = cast(uint)structDecl.structSize;
                    
                    // Allocate temp
                    out_ ~= Op.global_get;
                    leb128u(out_, emitter.spGlobal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, structSize);
                    out_ ~= Op.i32_sub;
                    out_ ~= Op.global_set;
                    leb128u(out_, emitter.spGlobal);
                    
                    // Copy from param pointer to SP
                    foreach (field; structDecl.fields) {
                        // Dest: SP + fieldOffset
                        out_ ~= Op.global_get;
                        leb128u(out_, emitter.spGlobal);
                        if (field.offset > 0) {
                            out_ ~= Op.i32_const;
                            leb128s(out_, cast(int)field.offset);
                            out_ ~= Op.i32_add;
                        }
                        
                        // Src: paramPtr + fieldOffset
                        out_ ~= Op.local_get;
                        leb128u(out_, paramInfo.localIndex);
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
                    
                    // Push SP as argument
                    out_ ~= Op.global_get;
                    leb128u(out_, emitter.spGlobal);
                    
                    totalCopySize += structSize;
                    continue;
                }
                
                // Check if argument is a static array local that needs copying
                if (auto localInfo = argIdent.name in locals) if (localInfo.isStaticArray) {
                    // Static array local - copy to temp, pass temp address
                    uint arrSize = localInfo.elementCount * localInfo.elementSize;

                    // Allocate temp: SP = SP - arrSize
                    out_ ~= Op.global_get;
                    leb128u(out_, emitter.spGlobal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, arrSize);
                    out_ ~= Op.i32_sub;
                    out_ ~= Op.global_set;
                    leb128u(out_, emitter.spGlobal);

                    // Copy from FP+offset to SP, word by word
                    for (uint off = 0; off < arrSize; off += 4) {
                        // Dest: SP + off
                        out_ ~= Op.global_get;
                        leb128u(out_, emitter.spGlobal);
                        if (off > 0) {
                            out_ ~= Op.i32_const;
                            leb128s(out_, off);
                            out_ ~= Op.i32_add;
                        }

                        // Src: FP + frameOffset + off
                        out_ ~= Op.local_get;
                        leb128u(out_, fpLocal);
                        out_ ~= Op.i32_const;
                        leb128s(out_, localInfo.frameOffset + cast(int)off);
                        out_ ~= Op.i32_add;
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

                    totalCopySize += arrSize;
                    continue;
                }

                // Check if argument is a static array param that needs copying
                if (auto paramInfo = argIdent.name in params) if (paramInfo.isStaticArray) {
                    // Static array param - already a pointer, copy from it
                    uint arrSize = paramInfo.elementCount * paramInfo.elementSize;

                    // Allocate temp
                    out_ ~= Op.global_get;
                    leb128u(out_, emitter.spGlobal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, arrSize);
                    out_ ~= Op.i32_sub;
                    out_ ~= Op.global_set;
                    leb128u(out_, emitter.spGlobal);

                    // Copy from param pointer to SP, word by word
                    for (uint off = 0; off < arrSize; off += 4) {
                        // Dest: SP + off
                        out_ ~= Op.global_get;
                        leb128u(out_, emitter.spGlobal);
                        if (off > 0) {
                            out_ ~= Op.i32_const;
                            leb128s(out_, off);
                            out_ ~= Op.i32_add;
                        }

                        // Src: paramPtr + off
                        out_ ~= Op.local_get;
                        leb128u(out_, paramInfo.localIndex);
                        if (off > 0) {
                            out_ ~= Op.i32_const;
                            leb128s(out_, cast(int)off);
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

                    // Push SP as argument
                    out_ ~= Op.global_get;
                    leb128u(out_, emitter.spGlobal);

                    totalCopySize += arrSize;
                    continue;
                }

                // Check if argument is a slice local
                if (auto sliceInfo = argIdent.name in locals) if (sliceInfo.isSlice) {
                    // Slice local - copy 12-byte slice struct to temp, pass temp address
                    enum sliceSize = WasmSliceLayout.sizeof;  // ptr, length, capacity
                    
                    // Allocate temp: SP = SP - 12
                    out_ ~= Op.global_get;
                    leb128u(out_, emitter.spGlobal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, sliceSize);
                    out_ ~= Op.i32_sub;
                    out_ ~= Op.global_set;
                    leb128u(out_, emitter.spGlobal);
                    
                    // Copy 3 fields (ptr, length, capacity) from FP+offset to SP
                    foreach (fieldOffset; [0, 4, 8]) {
                        // Dest: SP + fieldOffset
                        out_ ~= Op.global_get;
                        leb128u(out_, emitter.spGlobal);
                        if (fieldOffset > 0) {
                            out_ ~= Op.i32_const;
                            leb128s(out_, fieldOffset);
                            out_ ~= Op.i32_add;
                        }
                        
                        // Src: FP + srcOffset + fieldOffset
                        out_ ~= Op.local_get;
                        leb128u(out_, fpLocal);
                        out_ ~= Op.i32_const;
                        leb128s(out_, sliceInfo.frameOffset + fieldOffset);
                        out_ ~= Op.i32_add;
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
                    
                    totalCopySize += sliceSize;
                    continue;
                }
            }
            
            // Check for class→interface conversion (fat pointer)
            if (calleeDecl && argIdx < calleeDecl.parameters.length) {
                auto paramType = calleeDecl.parameters[argIdx].type;
                if (auto ifaceDecl = paramType.asInterface()) {
                        // Parameter expects interface - check if arg is a class
                        if (auto argIdent = cast(IdentifierExpression)arg) {
                            if (auto classLocal = argIdent.name in locals) {
                                if (classLocal.isClass) {
                                    // Class local → interface: emit fat pointer
                                    // obj_ptr: address of class local
                                    out_ ~= Op.local_get;
                                    leb128u(out_, fpLocal);
                                    out_ ~= Op.i32_const;
                                    leb128s(out_, classLocal.frameOffset);
                                    out_ ~= Op.i32_add;
                                    
                                    // itable_ptr: lookup itable base for this class+interface
                                    auto classDecl = classLocal.classDecl;
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
                            if (auto classParam = argIdent.name in params) {
                                if (classParam.isClass) {
                                    // Class param → interface: emit fat pointer
                                    // obj_ptr: the parameter value (already a pointer)
                                    out_ ~= Op.local_get;
                                    leb128u(out_, classParam.localIndex);
                                    
                                    // itable_ptr
                                    auto classDecl = classParam.classDecl;
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

            // Non-struct argument
            emitExpression(out_, arg);
        }
        
        // Call
        uint funcIdx = emitter.getFuncIndex(ident.name);
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
            else {
                // Non-literal expression: evaluate and print as i32
                // TODO: Support other types via expression type analysis
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
    
    /**
     * Emit a method call (obj.method(args)).
     * The hidden 'this' pointer is passed as the first argument.
     */
    void emitMethodCall(ref Appender!(ubyte[]) out_, MemberExpression memberExpr, Expression[] args) {
        // Get the struct type from the object
        auto objIdent = cast(IdentifierExpression)memberExpr.object;
        if (!objIdent) {
            throw new EmitError("Method call on non-identifier object not yet supported");
        }
        
        // Check locals first
        if (auto lInfo = objIdent.name in locals) {
            // Slice built-in methods
            if (lInfo.isSlice) {
                emitSliceBuiltinMethod(out_, objIdent.name, objIdent.name in locals, memberExpr.memberName, args);
                return;
            }
            // Interface local - handle separately
            if (lInfo.isInterface) {
                emitInterfaceMethodCall(out_, objIdent.name in locals, memberExpr.memberName, args);
                return;
            }
        }
        // Check params for interface
        if (auto pInfo = objIdent.name in params) {
            if (pInfo.isInterface) {
                emitInterfaceParamMethodCall(out_, objIdent.name in params, memberExpr.memberName, args);
                return;
            }
        }

        // Find the struct or class declaration to look up the method
        StructDecl structDecl = null;
        ClassDecl classDecl = null;

        if (auto lInfo = objIdent.name in locals) {
            if (lInfo.isStruct) structDecl = lInfo.structDecl;
            else if (lInfo.isClass) classDecl = lInfo.classDecl;
        }
        if (!structDecl && !classDecl) {
            if (auto pInfo = objIdent.name in params) {
                if (pInfo.isStruct) structDecl = pInfo.structDecl;
                else if (pInfo.isClass) classDecl = pInfo.classDecl;
            }
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
        // For a local struct/class: FP + frameOffset
        // For a param struct/class: the param value itself (already a pointer)
        if (auto lInfo = objIdent.name in locals) {
            if (lInfo.isStruct || lInfo.isClass) {
                out_ ~= Op.local_get;
                leb128u(out_, fpLocal);
                out_ ~= Op.i32_const;
                leb128s(out_, lInfo.frameOffset);
                out_ ~= Op.i32_add;
            }
        } else if (auto pInfo = objIdent.name in params) {
            if (pInfo.isStruct || pInfo.isClass) {
                out_ ~= Op.local_get;
                leb128u(out_, pInfo.localIndex);
            }
        }
        
        // Emit the other arguments
        foreach (arg; args) {
            emitExpression(out_, arg);
        }
        
        // For structs: direct call (no polymorphism)
        // For classes: call_indirect through vtable (virtual dispatch)
        if (structDecl) {
            // Struct method: direct call
            string mangledName = typeName ~ "_" ~ method.name;
            uint funcIdx = emitter.getFuncIndex(mangledName);
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
                string mangledName = typeName ~ "_" ~ method.name;
                uint funcIdx = emitter.getFuncIndex(mangledName);
                out_ ~= Op.call;
                leb128u(out_, funcIdx);
            } else {
                // Virtual dispatch:
                // tableIndex = (vtable_ptr & TABLE_BASE_MASK) + methodSlot
                
                // Load vtable_ptr from object (at offset 0)
                if (auto lInfo = objIdent.name in locals) {
                    if (lInfo.isClass) {
                        out_ ~= Op.local_get;
                        leb128u(out_, fpLocal);
                        out_ ~= Op.i32_const;
                        leb128s(out_, lInfo.frameOffset);
                        out_ ~= Op.i32_add;
                        out_ ~= Op.i32_load;
                        out_ ~= cast(ubyte)0x02;
                        leb128u(out_, 0);
                    }
                } else if (auto pInfo = objIdent.name in params) {
                    if (pInfo.isClass) {
                        out_ ~= Op.local_get;
                        leb128u(out_, pInfo.localIndex);
                        out_ ~= Op.i32_load;
                        out_ ~= cast(ubyte)0x02;
                        leb128u(out_, 0);
                    }
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
                string mangledName = typeName ~ "_" ~ method.name;
                uint funcIdx = emitter.getFuncIndex(mangledName);
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
    void emitInterfaceMethodCall(ref Appender!(ubyte[]) out_, LocalVarInfo* ifaceInfo,
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
        
        // Emit obj_ptr as 'this' argument (load from fat pointer offset 0)
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, ifaceInfo.frameOffset);  // fat pointer base
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;  // load obj_ptr
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
        // Emit other arguments
        foreach (arg; args) {
            emitExpression(out_, arg);
        }
        
        // Load itable_ptr (from fat pointer at ITABLE_OFFSET)
        // itable_ptr is packed: (typeId << TYPE_ID_SHIFT) | itableBase
        out_ ~= Op.local_get;
        leb128u(out_, fpLocal);
        out_ ~= Op.i32_const;
        leb128s(out_, ifaceInfo.frameOffset + WasmFatPointerLayout.ITABLE_OFFSET);
        out_ ~= Op.i32_add;
        out_ ~= Op.i32_load;  // load packed itable_ptr
        out_ ~= cast(ubyte)0x02;
        leb128u(out_, 0);
        
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
        // Use the emitter's getOrCreateMethodType function
        return emitter.getOrCreateMethodType(method);
    }
    
    /**
     * Emit interface method call for interface parameter.
     * Interface params are passed as two locals: obj_ptr, itable_ptr
     */
    void emitInterfaceParamMethodCall(ref Appender!(ubyte[]) out_, ParamVarInfo* ifaceInfo,
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
        
        // Emit obj_ptr as 'this' argument (from parameter local)
        out_ ~= Op.local_get;
        leb128u(out_, ifaceInfo.localIndex);
        
        // Emit other arguments
        foreach (arg; args) {
            emitExpression(out_, arg);
        }
        
        // Load itable_ptr from parameter local
        // itable_ptr is packed: (typeId << TYPE_ID_SHIFT) | itableBase
        out_ ~= Op.local_get;
        leb128u(out_, ifaceInfo.itableLocalIndex);
        
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
            return WasmSliceLayout.sizeof;
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

        // Emit arguments (with struct/slice pass-by-value handling)
        uint totalCopySize = 0;
        foreach (arg; args) {
            if (auto argIdent = cast(IdentifierExpression)arg) {
                // Struct local: copy to temp, pass temp address
                if (auto localInfo = argIdent.name in locals) if (localInfo.isStruct) {
                    auto argStructDecl = localInfo.structDecl;
                    uint structSize = cast(uint)argStructDecl.structSize;

                    // Allocate temp: SP = SP - structSize
                    out_ ~= Op.global_get;
                    leb128u(out_, emitter.spGlobal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, structSize);
                    out_ ~= Op.i32_sub;
                    out_ ~= Op.global_set;
                    leb128u(out_, emitter.spGlobal);

                    // Copy from FP+offset to SP
                    foreach (field; argStructDecl.fields) {
                        out_ ~= Op.global_get;
                        leb128u(out_, emitter.spGlobal);
                        if (field.offset > 0) {
                            out_ ~= Op.i32_const;
                            leb128s(out_, cast(int)field.offset);
                            out_ ~= Op.i32_add;
                        }
                        out_ ~= Op.local_get;
                        leb128u(out_, fpLocal);
                        out_ ~= Op.i32_const;
                        leb128s(out_, localInfo.frameOffset + cast(int)field.offset);
                        out_ ~= Op.i32_add;
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

                // Struct param: already a pointer, copy from it
                if (auto paramInfo = argIdent.name in params) if (paramInfo.isStruct) {
                    auto argStructDecl = paramInfo.structDecl;
                    uint structSize = cast(uint)argStructDecl.structSize;

                    out_ ~= Op.global_get;
                    leb128u(out_, emitter.spGlobal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, structSize);
                    out_ ~= Op.i32_sub;
                    out_ ~= Op.global_set;
                    leb128u(out_, emitter.spGlobal);

                    foreach (field; argStructDecl.fields) {
                        out_ ~= Op.global_get;
                        leb128u(out_, emitter.spGlobal);
                        if (field.offset > 0) {
                            out_ ~= Op.i32_const;
                            leb128s(out_, cast(int)field.offset);
                            out_ ~= Op.i32_add;
                        }
                        out_ ~= Op.local_get;
                        leb128u(out_, paramInfo.localIndex);
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
                if (auto lInfo = ident.name in locals) {
                    if (lInfo.isSlice) {
                        emitSliceAppend(out_, ident.name, ident.name in locals, expr.right);
                        return;
                    }
                }
            }
            throw new EmitError("Concat-assign (~=) only supported on slice locals");
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
                if (auto thisInfo = "this" in params) {
                    // Calculate address: this + fieldOffset
                    out_ ~= Op.local_get;
                    leb128u(out_, thisInfo.localIndex);
                    if (field.offset > 0) {
                        out_ ~= Op.i32_const;
                        leb128s(out_, cast(int)field.offset);
                        out_ ~= Op.i32_add;
                    }
                    
                    // Emit value
                    emitExpression(out_, expr.right);
                    
                    // For consistent semantics, assignment should leave value on stack
                    // Store to temp, emit again for stack value
                    // We need to: [addr, value] -> store, then push value back
                    // Use a temp local to hold the value
                    
                    // Actually, simplest approach: emit value twice (before address)
                    // But we already emitted address. Let's just store and push 0
                    // as a placeholder - the expressionHasValue will need to handle this
                    
                    // Store (consumes addr and value)
                    out_ ~= Op.i32_store;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    
                    // For now, emit value again so assignment has a value
                    // This re-evaluates the expression (not ideal but works for simple cases)
                    emitExpression(out_, expr.right);
                    return;
                }
            }
        }
        
        // Regular local variable assignment
        // Look up symbol to get uniqueLocalId
        auto symbol = emitter.symbolTable.lookupSymbol(ident.name);
        uint wasmIdx = uint.max;
        if (symbol && symbol.uniqueLocalId != uint.max) {
            if (auto idx = symbol.uniqueLocalId in localIdToWasmIdx) {
                wasmIdx = *idx;
            }
        }
        // Fallback to legacy name-based lookup
        if (wasmIdx == uint.max) {
            if (auto idxPtr = ident.name in localIndex) {
                wasmIdx = *idxPtr;
            }
        }
        
        if (wasmIdx != uint.max) {
            // Handle compound assignment operators (+=, -=, etc.)
            if (expr.operator != AssignmentExpression.Operator.Assign) {
                // Load current value
                out_ ~= Op.local_get;
                leb128u(out_, wasmIdx);
                
                // Emit RHS value
                emitExpression(out_, expr.right);
                
                // Apply operation based on operator
                final switch (expr.operator) {
                    case AssignmentExpression.Operator.Assign:
                        assert(false); // Handled in else branch
                    case AssignmentExpression.Operator.AddAssign:
                        out_ ~= Op.i32_add;
                        break;
                    case AssignmentExpression.Operator.SubtractAssign:
                        out_ ~= Op.i32_sub;
                        break;
                    case AssignmentExpression.Operator.MultiplyAssign:
                        out_ ~= Op.i32_mul;
                        break;
                    case AssignmentExpression.Operator.DivideAssign:
                        out_ ~= Op.i32_div_s;
                        break;
                    case AssignmentExpression.Operator.ModuloAssign:
                        out_ ~= Op.i32_rem_s;
                        break;
                    case AssignmentExpression.Operator.AndAssign:
                        out_ ~= Op.i32_and;
                        break;
                    case AssignmentExpression.Operator.OrAssign:
                        out_ ~= Op.i32_or;
                        break;
                    case AssignmentExpression.Operator.XorAssign:
                        out_ ~= Op.i32_xor;
                        break;
                    case AssignmentExpression.Operator.ShiftLeftAssign:
                        out_ ~= Op.i32_shl;
                        break;
                    case AssignmentExpression.Operator.ShiftRightAssign:
                        out_ ~= Op.i32_shr_s;
                        break;
                    case AssignmentExpression.Operator.ConcatAssign:
                        throw new EmitError("~= on local should use slice path");
                }
            } else {
                // Simple assignment: emit value
                emitExpression(out_, expr.right);
            }
            
            // Store and leave value on stack (assignment is an expression)
            out_ ~= Op.local_tee;
            leb128u(out_, wasmIdx);
        } else {
            throw new EmitError("Unknown identifier in assignment: " ~ ident.name);
        }
    }
    
    /**
     * Emit assignment to a struct field (p.x = value)
     */
    void emitMemberAssignment(ref Appender!(ubyte[]) out_, MemberExpression member, Expression value) {
        auto objIdent = cast(IdentifierExpression)member.object;
        if (!objIdent) {
            throw new EmitError("Complex member assignment targets not yet supported");
        }
        
        // Check if it's a local struct/class
        if (auto info = objIdent.name in locals) {
            if (info.isStruct || info.isClass) {
                auto aggr = info.isStruct ? cast(AggregateDecl)info.structDecl
                                          : cast(AggregateDecl)info.classDecl;
                auto field = aggr.getField(member.memberName);
                if (!field) {
                    throw new EmitError(format("Unknown field '%s' in '%s'",
                                              member.memberName, aggr.name));
                }

                // Calculate address: FP + frameOffset + fieldOffset
                out_ ~= Op.local_get;
                leb128u(out_, fpLocal);
                out_ ~= Op.i32_const;
                leb128s(out_, info.frameOffset + cast(int)field.offset);
                out_ ~= Op.i32_add;

                emitExpression(out_, value);

                out_ ~= Op.i32_store;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);

                // Re-load for expression value
                out_ ~= Op.local_get;
                leb128u(out_, fpLocal);
                out_ ~= Op.i32_const;
                leb128s(out_, info.frameOffset + cast(int)field.offset);
                out_ ~= Op.i32_add;
                out_ ~= Op.i32_load;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
                return;
            }

            // Slice .length assignment
            if (info.isSlice && member.memberName == "length") {
                emitSliceLengthAssignment(out_, objIdent.name, objIdent.name in locals, value);
                return;
            }
        }

        // Check if it's a struct/class parameter
        if (auto pinfo = objIdent.name in params) {
            if (pinfo.isStruct || pinfo.isClass) {
                auto aggr = pinfo.isStruct ? cast(AggregateDecl)pinfo.structDecl
                                           : cast(AggregateDecl)pinfo.classDecl;
                auto field = aggr.getField(member.memberName);
                if (!field) {
                    throw new EmitError(format("Unknown field '%s' in '%s'",
                                              member.memberName, aggr.name));
                }

                out_ ~= Op.local_get;
                leb128u(out_, pinfo.localIndex);
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
                out_ ~= Op.local_get;
                leb128u(out_, pinfo.localIndex);
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
                                    LocalVarInfo* sliceInfo, Expression newLengthExpr) {
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
        leb128s(out_, sliceAddr + WasmSliceLayout.CAPACITY_OFFSET);
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
        
        // Allocate new buffer: __alloc(newLength * 4)
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
        uint allocIdx = emitter.getFuncIndex("__alloc");
        out_ ~= Op.call;
        leb128u(out_, allocIdx);
        
        // Store newBuffer at SP-8
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, 8);
        out_ ~= Op.i32_sub;
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
        leb128s(out_, sliceAddr + WasmSliceLayout.LENGTH_OFFSET);
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
        leb128s(out_, sliceAddr + WasmSliceLayout.CAPACITY_OFFSET);
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
        leb128s(out_, sliceAddr + WasmSliceLayout.LENGTH_OFFSET);
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
        leb128s(out_, sliceAddr + WasmSliceLayout.LENGTH_OFFSET);
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
        leb128s(out_, sliceAddr + WasmSliceLayout.LENGTH_OFFSET);
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
                    // Check unified locals/params
                    StructDecl structDecl = null;
                    if (auto lInfo = objIdent.name in locals) {
                        if (lInfo.isSlice && memberExpr.memberName == "reserve")
                            return false;  // reserve() returns void
                        if (lInfo.isStruct)
                            structDecl = lInfo.structDecl;
                    }
                    if (!structDecl) {
                        if (auto pInfo = objIdent.name in params) {
                            if (pInfo.isStruct) structDecl = pInfo.structDecl;
                        }
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
        if (auto basic = cast(BasicType)t) {
            return basic.kind == BasicType.Kind.Void;
        }
        return false;
    }
}
