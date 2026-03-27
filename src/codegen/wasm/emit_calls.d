/**
 * CallEmitter — mixin for FuncContext
 * Auto-extracted from func_context.d
 */
module codegen.wasm.emit_calls;

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

mixin template CallEmitter() {
    void emitEmplaceCall(ref Appender!(ubyte[]) out_, CallExpression expr) {
        Expression[] fieldArgs = expr.arguments[1 .. $];

        // Emit pointer value and save to tempLocalA
        emitExpression(out_, expr.arguments[0]);
        emitLocalSet(out_, tempLocalA);

        if (expr.resolvedEmplaceClass) {
            // Class emplace: store vtable pointer + fields
            emitVtableStore(out_, expr.resolvedEmplaceClass);
            emitFieldStores(out_, expr.resolvedEmplaceClass, fieldArgs);
        } else {
            // Struct emplace: fields only
            emitFieldStores(out_, expr.resolvedEmplaceStruct, fieldArgs);
        }

        // Return the pointer (same as input)
        emitLocalGet(out_, tempLocalA);
    }

    /// Emit new Type(args) — allocate + initialize (structs and classes)
    void emitNewExpression(ref Appender!(ubyte[]) out_, NewExpression expr) {
        if (expr.resolvedClass) {
            emitNewClass(out_, expr);
            return;
        }

        auto structDecl = expr.resolvedStruct;

        if (expr.stackPromoted) {
            // Stack-promoted: use pre-allocated shadow stack space
            // tempLocalA = FP + stackFrameOffset
            emitFPOffset(out_, cast(int)expr.stackFrameOffset);
            emitLocalSet(out_, tempLocalA);

            // Store fields (same as heap path)
            emitFieldStores(out_, structDecl, expr.arguments);

            // Return pointer (FP + offset)
            emitLocalGet(out_, tempLocalA);
            return;
        }

        int structSize = cast(int)structDecl.structSize;

        // __alloc(sizeof)
        emitI32Const(out_, structSize);
        emitWasmCall(out_, emitter.getFuncIndex("__alloc"));

        // Save returned pointer to tempLocalA
        emitLocalSet(out_, tempLocalA);

        // Store fields
        emitFieldStores(out_, structDecl, expr.arguments);

        // Return pointer
        emitLocalGet(out_, tempLocalA);
    }

    /// Store packed vtable pointer at tempLocalA + 0
    private void emitVtableStore(ref Appender!(ubyte[]) out_, ClassDecl classDecl) {
        uint packed = WasmVtablePacking.pack(classDecl.typeId, classDecl.tableBase);
        emitLocalGet(out_, tempLocalA);
        emitI32Const(out_, cast(int)packed);
        emitI32Store(out_);
    }

    /// Emit new Class(args) — allocate + vtable + field init or constructor call
    void emitNewClass(ref Appender!(ubyte[]) out_, NewExpression expr) {
        auto classDecl = expr.resolvedClass;
        int classSize = cast(int)classDecl.classSize;

        // 1. __alloc(classSize)
        emitI32Const(out_, classSize);
        emitWasmCall(out_, emitter.getFuncIndex("__alloc"));
        emitLocalSet(out_, tempLocalA);

        // 2. Store vtable pointer at offset 0
        emitVtableStore(out_, classDecl);

        // 3. Initialize fields (or call constructor)
        if (classDecl.constructor !is null) {
            // Direct constructor call: this=tempLocalA, args...
            emitLocalGet(out_, tempLocalA);
            foreach (arg; expr.arguments)
                emitExpression(out_, arg);
            uint funcIdx = emitter.getFuncIndex(classDecl.constructor.mangledName, expr.location);
            emitWasmCall(out_, funcIdx);
        } else {
            // Field-by-field init using shared helper
            emitFieldStores(out_, classDecl, expr.arguments);
        }

        // 4. Return pointer
        emitLocalGet(out_, tempLocalA);
    }

    /**
     * Emit a function literal expression.
     * Pushes {tableIndex, envPtr} onto the WASM stack.
     * For Phase 1 (non-capturing): envPtr is always 0.
     */
    void emitFunctionLiteral(ref Appender!(ubyte[]) out_, FunctionLiteralExpression funcLit) {
        auto lifted = funcLit.liftedFunction;
        if (lifted is null)
            throw new EmitError("Function literal has no lifted function", funcLit.location);

        uint tableIdx = emitter.getLambdaTableIndex(lifted.mangledName);

        if (!funcLit.isNonCapturing) {
            // Capturing lambda: construct env struct on shadow stack
            // envFrameOffset was set during collectLocals
            foreach (i, capName; funcLit.capturedNames) {
                // Store pointer to captured var at env + captureOffset
                // dest: FP + envFrameOffset + capturedOffsets[i]
                emitFPOffset(out_, funcLit.envFrameOffset + funcLit.capturedOffsets[i]);

                // src: address of captured variable (FP + its frameOffset)
                auto capInfo = resolveVar(uint.max, capName);
                if (capInfo is null)
                    throw new EmitError("Captured variable not found: " ~ capName, funcLit.location);
                emitVarAddress(out_, capInfo);

                // Store address into env slot
                emitI32Store(out_);
            }

            // Push {tableIndex, envPtr}
            emitI32Const(out_, cast(int)tableIdx);
            // envPtr = FP + envFrameOffset (absolute address via SP)
            emitFPOffset(out_, funcLit.envFrameOffset);
        } else {
            // Non-capturing: push {tableIndex, 0}
            emitI32Const(out_, cast(int)tableIdx);
            emitI32Const(out_, 0);
        }
    }

    /**
     * Emit delegate variable declaration.
     * Stores {tableIndex, envPtr} from the initializer expression into shadow stack.
     */
    void emitDelegateVarDecl(ref Appender!(ubyte[]) out_, VariableDeclarationStatement varDecl) {
        auto info = resolveVar(varDecl.uniqueLocalId, varDecl.name);
        if (info is null)
            throw new EmitError("Delegate variable not found: " ~ varDecl.name, varDecl.location);

        if (varDecl.initializer is null)
            return;  // Uninitialized delegate — leave as zero

        // Emit the initializer — pushes {tableIndex, envPtr} (two i32s)
        emitExpression(out_, varDecl.initializer);

        // Stack: [tableIndex, envPtr]
        // Store envPtr at FP + offset + 4
        emitLocalSet(out_, tempLocalA);

        emitLocalSet(out_, tempLocalB);

        // Store tableIndex at FP + frameOffset + 0
        emitVarAddress(out_, info);
        emitLocalGet(out_, tempLocalB);
        emitI32Store(out_);

        // Store envPtr at FP + frameOffset + 4
        emitVarAddress(out_, info);
        emitI32Const(out_, 4);
        out_ ~= Op.i32_add;
        emitLocalGet(out_, tempLocalA);
        emitI32Store(out_);
    }

    /**
     * Emit a delegate call via call_indirect.
     * Loads {tableIndex, envPtr} from delegate variable, pushes args, call_indirect.
     */
    void emitDelegateCall(ref Appender!(ubyte[]) out_, VarInfo* dgInfo,
                          Expression[] args, FunctionDecl liftedFunc) {
        // 1. Push __env (envPtr from delegate struct)
        emitVarAddress(out_, dgInfo);
        emitI32Const(out_, 4);
        out_ ~= Op.i32_add;
        emitI32Load(out_);

        // 2. Push user arguments
        foreach (arg; args)
            emitExpression(out_, arg);

        // 3. Push tableIndex (consumed by call_indirect — must be on top of stack)
        emitVarAddress(out_, dgInfo);
        emitI32Load(out_);

        // 4. call_indirect with the delegate's type signature
        uint typeIdx;
        if (liftedFunc !is null) {
            typeIdx = emitter.getOrCreateDelegateCallType(liftedFunc);
        } else if (auto funcType = cast(FunctionType)dgInfo.type) {
            typeIdx = emitter.getOrCreateDelegateCallTypeFromFuncType(funcType);
        } else {
            throw new EmitError("Cannot resolve delegate type for call_indirect", SourceLocation.init);
        }
        out_ ~= Op.call_indirect;
        leb128u(out_, typeIdx);
        leb128u(out_, 0);  // table index 0
    }

    void emitIncDec(ref Appender!(ubyte[]) out_, UnaryExpression expr, bool inc) {
        auto ident = cast(IdentifierExpression)expr.operand;
        if (!ident) {
            throw new EmitError("Increment/decrement requires identifier", expr.location);
        }

        // Check unified map first (locals and params)
        if (auto info = resolveVar(ident.resolvedLocalId, ident.name)) {
            if (info.addrMode != AddrMode.wasmLocal)
                throw new EmitError("Increment/decrement requires scalar variable", ident.location);
            auto idx = info.wasmLocalIdx;

            bool isF32 = idx < localTypes.length && localTypes[idx] == ValType.f32;
            bool isF64 = idx < localTypes.length && localTypes[idx] == ValType.f64;

            if (expr.isPostfix) {
                emitLocalGet(out_, idx);
                emitLocalGet(out_, idx);
                if (isF32) {
                    emitF32Const(out_, 1.0f);
                    out_ ~= (inc ? Op.f32_add : Op.f32_sub);
                } else if (isF64) {
                    emitF64Const(out_, 1.0);
                    out_ ~= (inc ? Op.f64_add : Op.f64_sub);
                } else {
                    emitI32Const(out_, 1);
                    out_ ~= (inc ? Op.i32_add : Op.i32_sub);
                }
                emitLocalSet(out_, idx);
            } else {
                emitLocalGet(out_, idx);
                if (isF32) {
                    emitF32Const(out_, 1.0f);
                    out_ ~= (inc ? Op.f32_add : Op.f32_sub);
                } else if (isF64) {
                    emitF64Const(out_, 1.0);
                    out_ ~= (inc ? Op.f64_add : Op.f64_sub);
                } else {
                    emitI32Const(out_, 1);
                    out_ ~= (inc ? Op.i32_add : Op.i32_sub);
                }
                emitLocalTee(out_, idx);
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
                        emitGlobalGet(out_, gIdx);
                        emitGlobalGet(out_, gIdx);
                        emitI32Const(out_, 1);
                        out_ ~= (inc ? Op.i32_add : Op.i32_sub);
                        emitGlobalSet(out_, gIdx);
                    } else {
                        // Modify, then return new value
                        emitGlobalGet(out_, gIdx);
                        emitI32Const(out_, 1);
                        out_ ~= (inc ? Op.i32_add : Op.i32_sub);
                        // global doesn't have tee, so dup before set
                        // store new value in global, leave copy on stack
                        // We need: [newVal] on stack + global = newVal
                        // Emit: compute newVal, global_set, global_get
                        emitGlobalSet(out_, gIdx);
                        emitGlobalGet(out_, gIdx);
                    }
                    return;
                }
            }
        }

        throw new EmitError("Increment/decrement: unknown variable: " ~ ident.name, ident.location);
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
            throw new EmitError("Indirect calls not yet supported", expr.location);
        }

        // Check if the callee is a delegate/function variable — emit call_indirect
        if (auto dgInfo = resolveVar(ident.resolvedLocalId, ident.name)) {
            if (dgInfo.isDelegate()) {
                emitDelegateCall(out_, dgInfo, expr.arguments, dgInfo.delegateLiftedFunc);
                return;
            }
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
        
        // emplace(ptr, args...) — compiler intrinsic: construct struct at pointer
        if (ident.name == "emplace" && (expr.resolvedEmplaceStruct !is null || expr.resolvedEmplaceClass !is null)) {
            emitEmplaceCall(out_, expr);
            return;
        }

        // Special handling for __writeln: lower to typed CTFE print calls
        if (ident.name == "__writeln") {
            emitWritelnCall(out_, expr.arguments);
            return;
        }

        // __arena_new() / __arena_drop() — arena sub-generation management
        if (ident.name == "__arena_new") {
            emitArenaPointer(out_);
            emitWasmCall(out_, emitter.arenaNewFuncIndex);
            return;
        }
        if (ident.name == "__arena_drop") {
            emitArenaPointer(out_);
            emitWasmCall(out_, emitter.arenaDropFuncIndex);
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
            emitGlobalGet(out_, emitter.spGlobal);
            emitI32Const(out_, resultTempSize);
            out_ ~= Op.i32_sub;
            emitGlobalSet(out_, emitter.spGlobal);

            // Push result pointer as first hidden argument
            emitGlobalGet(out_, emitter.spGlobal);
        }

        // Push hidden arena pointer if callee needs it
        // (exported free functions like "main" don't take arena param)
        bool calleeNeedsArena = (calleeDecl && calleeDecl.needsArena && calleeDecl.name != "main")
                || (expr.resolvedInstantiation && expr.resolvedInstantiation.needsArena);
        if (calleeNeedsArena) {
            emitArenaPointer(out_);
        }

        // Track ref scalar spills — need to reload values from shadow stack after the call
        static struct RefSpillInfo {
            uint wasmLocalIdx;  // WASM local to reload into
            uint spOffset;      // offset from post-spill SP to the spilled value
        }
        RefSpillInfo[] refSpills;

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
                        emitGlobalGet(out_, emitter.spGlobal);
                        emitI32Const(out_, structSize);
                        out_ ~= Op.i32_sub;
                        emitGlobalSet(out_, emitter.spGlobal);

                        // Copy fields from source to SP (blit — type-aware load/store)
                        foreach (field; structDecl.fields) {
                            auto fbt = cast(BasicType)field.type;
                            bool fIsFloat = fbt && (fbt.kind == BasicType.Kind.Float64 || fbt.kind == BasicType.Kind.Float32);
                            uint fSize = cast(uint)field.size;

                            // Dest: SP + fieldOffset
                            emitGlobalGet(out_, emitter.spGlobal);
                            if (field.offset > 0) {
                                emitI32Const(out_, cast(int)field.offset);
                                out_ ~= Op.i32_add;
                            }

                            // Src: var address + fieldOffset
                            emitVarAddress(out_, argInfo);
                            if (field.offset > 0) {
                                emitI32Const(out_, cast(int)field.offset);
                                out_ ~= Op.i32_add;
                            }
                            emitLoadForSize(out_, fSize, fIsFloat);

                            // Store
                            emitStoreForSize(out_, fSize, fIsFloat);
                        }

                        // Push SP (address of copy) as argument
                        emitGlobalGet(out_, emitter.spGlobal);

                        totalCopySize += structSize;
                        continue;
                    }

                    if (argInfo.isStaticArray) {
                        // Static array - copy to temp, pass temp address
                        uint arrSize = argInfo.elementCount * argInfo.elementSize;

                        emitGlobalGet(out_, emitter.spGlobal);
                        emitI32Const(out_, arrSize);
                        out_ ~= Op.i32_sub;
                        emitGlobalSet(out_, emitter.spGlobal);

                        // Copy word by word
                        for (uint off = 0; off < arrSize; off += 4) {
                            emitGlobalGet(out_, emitter.spGlobal);
                            if (off > 0) {
                                emitI32Const(out_, off);
                                out_ ~= Op.i32_add;
                            }

                            emitVarAddress(out_, argInfo);
                            if (off > 0) {
                                emitI32Const(out_, cast(int)off);
                                out_ ~= Op.i32_add;
                            }
                            emitI32Load(out_);

                            emitI32Store(out_);
                        }

                        emitGlobalGet(out_, emitter.spGlobal);

                        totalCopySize += arrSize;
                        continue;
                    }

                    if (argInfo.isSlice) {
                        // Slice - copy 12-byte slice struct to temp, pass temp address
                        const sliceSize = sliceLayout.totalSize;

                        emitGlobalGet(out_, emitter.spGlobal);
                        emitI32Const(out_, sliceSize);
                        out_ ~= Op.i32_sub;
                        emitGlobalSet(out_, emitter.spGlobal);

                        // Copy 3 fields (ptr, length, capacity)
                        foreach (fieldOffset; [0, 4, 8]) {
                            emitGlobalGet(out_, emitter.spGlobal);
                            if (fieldOffset > 0) {
                                emitI32Const(out_, fieldOffset);
                                out_ ~= Op.i32_add;
                            }

                            emitVarAddress(out_, argInfo);
                            if (fieldOffset > 0) {
                                emitI32Const(out_, fieldOffset);
                                out_ ~= Op.i32_add;
                            }
                            emitI32Load(out_);

                            emitI32Store(out_);
                        }

                        emitGlobalGet(out_, emitter.spGlobal);

                        totalCopySize += sliceSize;
                        continue;
                    }

                    if (argInfo.isDelegate) {
                        // Delegate - copy 8-byte fat pointer to temp, pass temp address
                        enum delegateSize = 8;

                        emitGlobalGet(out_, emitter.spGlobal);
                        emitI32Const(out_, delegateSize);
                        out_ ~= Op.i32_sub;
                        emitGlobalSet(out_, emitter.spGlobal);

                        // Copy 2 fields (tableIndex, envPtr)
                        foreach (fieldOffset; [0, 4]) {
                            emitGlobalGet(out_, emitter.spGlobal);
                            if (fieldOffset > 0) {
                                emitI32Const(out_, fieldOffset);
                                out_ ~= Op.i32_add;
                            }

                            emitVarAddress(out_, argInfo);
                            if (fieldOffset > 0) {
                                emitI32Const(out_, fieldOffset);
                                out_ ~= Op.i32_add;
                            }
                            emitI32Load(out_);

                            emitI32Store(out_);
                        }

                        emitGlobalGet(out_, emitter.spGlobal);

                        totalCopySize += delegateSize;
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
                                    emitI32Const(out_, *itableBase);
                                } else {
                                    throw new EmitError("Class " ~ classDecl.name ~
                                        " does not implement interface " ~ ifaceDecl.name, arg.location);
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
                    throw new EmitError("Complex slice source not supported in call argument", sliceArg.location);
                }

                auto srcInfo = resolveVar(sourceIdent.resolvedLocalId, sourceIdent.name);
                if (!srcInfo || (!srcInfo.isSlice && !srcInfo.isStaticArray)) {
                    throw new EmitError("Can only sub-slice array-like variables: " ~ sourceIdent.name, sourceIdent.location);
                }
                uint sourceElemSize = srcInfo.elementSize;

                const sliceSize = sliceLayout.totalSize;

                // Allocate temp: SP = SP - 12
                emitGlobalGet(out_, emitter.spGlobal);
                emitI32Const(out_, sliceSize);
                out_ ~= Op.i32_sub;
                emitGlobalSet(out_, emitter.spGlobal);

                // Store ptr = base + start * elemSize at SP+0
                emitGlobalGet(out_, emitter.spGlobal);

                // Load base address
                if (srcInfo.isSlice) {
                    emitVarAddress(out_, srcInfo);
                    emitI32Load(out_);
                } else {
                    // Static array: address IS the data
                    emitVarAddress(out_, srcInfo);
                }

                // Add start * elemSize
                emitExpression(out_, sliceArg.start);
                emitI32Const(out_, sourceElemSize);
                out_ ~= Op.i32_mul;
                out_ ~= Op.i32_add;

                emitI32Store(out_);

                // Store length = end - start at SP+4
                emitGlobalGet(out_, emitter.spGlobal);
                emitI32Const(out_, sliceLayout.lengthOffset);
                out_ ~= Op.i32_add;

                emitExpression(out_, sliceArg.end);
                emitExpression(out_, sliceArg.start);
                out_ ~= Op.i32_sub;

                emitI32Store(out_);

                // Store capacity = length at SP+8
                emitGlobalGet(out_, emitter.spGlobal);
                emitI32Const(out_, sliceLayout.capacityOffset);
                out_ ~= Op.i32_add;

                emitExpression(out_, sliceArg.end);
                emitExpression(out_, sliceArg.start);
                out_ ~= Op.i32_sub;

                emitI32Store(out_);

                // Push SP (address of temp slice) as argument
                emitGlobalGet(out_, emitter.spGlobal);

                totalCopySize += sliceSize;
                continue;
            }

            // ref parameter: pass address of the argument variable
            // For WASM locals (scalars), spill to shadow stack temp to get an address
            if (calleeDecl && argIdx < calleeDecl.parameters.length &&
                calleeDecl.parameters[argIdx].isRef) {
                if (auto argIdent = cast(IdentifierExpression)arg) {
                    if (auto argInfo = resolveVar(argIdent.resolvedLocalId, argIdent.name)) {
                        if (argInfo.addrMode == AddrMode.wasmLocal) {
                            // Scalar in WASM local — spill to shadow stack temp
                            // Allocate 4 bytes: SP = SP - 4
                            emitGlobalGet(out_, emitter.spGlobal);
                            emitI32Const(out_, 4);
                            out_ ~= Op.i32_sub;
                            emitGlobalSet(out_, emitter.spGlobal);

                            // Store current value: *SP = local_get
                            emitGlobalGet(out_, emitter.spGlobal);
                            emitLocalGet(out_, argInfo.wasmLocalIdx);
                            emitI32Store(out_);

                            // Push SP as the ref address argument
                            emitGlobalGet(out_, emitter.spGlobal);

                            // Track for post-call reload and SP restore
                            refSpills ~= RefSpillInfo(argInfo.wasmLocalIdx, totalCopySize);
                            totalCopySize += 4;
                            continue;
                        } else {
                            // Already has a memory address (shadow stack or param pointer)
                            emitVarAddress(out_, argInfo);
                            continue;
                        }
                    }
                }
                throw new EmitError("ref argument must be a variable", arg.location);
            }

            // Non-struct argument
            emitExpression(out_, arg);
            // Implicit f64→f32 for float params passed double arguments
            if (calleeDecl && argIdx < calleeDecl.parameters.length) {
                auto paramType = calleeDecl.parameters[argIdx].type;
                if (auto pbt = cast(BasicType)paramType)
                    if (pbt.kind == BasicType.Kind.Float32 && isF64Expression(arg))
                        out_ ~= Op.f32_demote_f64;
            }
        }

        // Call — use IFTI resolved name if available
        string callName = expr.resolvedInstantiation ? expr.resolvedInstantiation.name : ident.name;
        uint funcIdx = emitter.getFuncIndex(callName, expr.location);
        emitWasmCall(out_, funcIdx);

        // Reload ref-spilled scalars: callee may have modified them through the pointer
        foreach (ref spill; refSpills) {
            // Load modified value from shadow stack back into the WASM local
            emitGlobalGet(out_, emitter.spGlobal);
            if (spill.spOffset > 0) {
                emitI32Const(out_, spill.spOffset);
                out_ ~= Op.i32_add;
            }
            emitI32Load(out_);
            emitLocalSet(out_, spill.wasmLocalIdx);
        }

        // Restore SP after call (deallocate arg copies and ref spill temps)
        if (totalCopySize > 0) {
            emitGlobalGet(out_, emitter.spGlobal);
            emitI32Const(out_, totalCopySize);
            out_ ~= Op.i32_add;
            emitGlobalSet(out_, emitter.spGlobal);
        }

        // For aggregate-returning functions, leave result address on WASM stack
        // (result temp persists until function epilogue, like emitStructConstructionToTemp)
        if (calleeHasLargeReturn) {
            emitGlobalGet(out_, emitter.spGlobal);
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
            throw new EmitError("Template instantiation not resolved: " ~ expr.templateName, expr.location);

        // Emit call arguments
        foreach (arg; expr.callArguments) {
            emitExpression(out_, arg);
        }

        // Call the mangled function
        uint funcIdx = emitter.getFuncIndex(inst.name, expr.location);
        emitWasmCall(out_, funcIdx);
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
        } else if (name == "__intrinsic_shl_i64") {
            out_ ~= Op.i64_shl;
        } else if (name == "__intrinsic_shr_s_i64") {
            out_ ~= Op.i64_shr_s;
        } else if (name == "__intrinsic_shr_u_i64") {
            out_ ~= Op.i64_shr_u;
        } else if (name == "__intrinsic_unreachable") {
            out_ ~= Op.unreachable;
        } else {
            throw new EmitError("Unknown intrinsic: " ~ name, SourceLocation.init);
        }
    }

    /**
     * Emit __writeln(args...) by lowering to typed CTFE write calls.
     * Each argument is printed according to its type, followed by a newline.
     * Uses __ctfe_write_* (building blocks without prefix) not __ctfe_print_*.
     */
    private void emitWritelnHostCall(ref Appender!(ubyte[]) out_, string hostFunc) {
        emitter.neededCTFEImports[hostFunc] = true;
        uint funcIdx = emitter.getFuncIndex(hostFunc);
        emitWasmCall(out_, funcIdx);
    }

    private void emitWritelnString(ref Appender!(ubyte[]) out_, Expression arg) {
        // String needs (ptr, len) unpacked from the array struct.
        // String literals and manifest constants use registerArrayLiteral for a static struct.
        // Variables push the struct address via emitExpression; we load ptr/len from it.
        if (auto literal = cast(LiteralExpression)arg) {
            if (literal.value.type == typeid(string)) {
                uint structAddr = emitter.registerArrayLiteral(literal.value.get!string());
                emitI32Const(out_, structAddr);
                emitI32Load(out_);
                emitI32Const(out_, structAddr + 4);
                emitI32Load(out_);
                emitWritelnHostCall(out_, "__ctfe_write_str");
                return;
            }
        }
        if (auto manifest = getStringManifest(arg)) {
            manifest.ensureEvaluated();
            uint structAddr = emitter.registerArrayLiteral(manifest.ctfeStringValue);
            emitI32Const(out_, structAddr);
            emitI32Load(out_);
            emitI32Const(out_, structAddr + 4);
            emitI32Load(out_);
            emitWritelnHostCall(out_, "__ctfe_write_str");
            return;
        }
        // String variable: emitExpression pushes struct address, load ptr+len
        emitExpression(out_, arg);
        emitLocalSet(out_, tempLocalA);
        emitLocalGet(out_, tempLocalA);
        emitI32Load(out_);
        emitLocalGet(out_, tempLocalA);
        emitI32Load(out_, 4);
        emitWritelnHostCall(out_, "__ctfe_write_str");
    }

    void emitWritelnCall(ref Appender!(ubyte[]) out_, Expression[] args) {
        foreach (arg; args) {
            // Dispatch on expr.type (set by type checker) to pick the right host call.
            // Note: manifest constants may have incorrect type (Int32 placeholder)
            // before CTFE evaluation, so we always check AST patterns too.
            Type argType = arg.type ? arg.type.resolve() : null;

            // String check: type-based OR AST-based (string literal / string manifest)
            bool isStr = false;
            if (auto at = cast(ArrayType)argType) {
                auto bt = cast(BasicType)at.elementType;
                isStr = bt !is null && (bt.kind == BasicType.Kind.Char || bt.kind == BasicType.Kind.UInt8);
            }
            if (!isStr) {
                if (auto lit = cast(LiteralExpression)arg)
                    isStr = lit.value.type == typeid(string);
            }
            if (!isStr && getStringManifest(arg) !is null)
                isStr = true;

            if (isStr) {
                emitWritelnString(out_, arg);
            } else if (isF64Expression(arg)) {
                emitExpression(out_, arg);
                emitWritelnHostCall(out_, "__ctfe_write_f64");
            } else if (isF32Expression(arg)) {
                emitExpression(out_, arg);
                out_ ~= Op.f64_promote_f32;
                emitWritelnHostCall(out_, "__ctfe_write_f64");
            } else if (isI64Expression(arg)) {
                emitExpression(out_, arg);
                emitWritelnHostCall(out_, "__ctfe_write_i64");
            } else {
                auto bt = cast(BasicType)argType;
                if (bt && bt.kind == BasicType.Kind.Bool) {
                    emitExpression(out_, arg);
                    emitWritelnHostCall(out_, "__ctfe_write_bool");
                } else {
                    // Check for float literal when type info is wrong/missing
                    if (auto lit = cast(LiteralExpression)arg) {
                        if (lit.value.type == typeid(double)) {
                            emitExpression(out_, arg);
                            emitWritelnHostCall(out_, "__ctfe_write_f64");
                            continue;
                        }
                    }
                    // int, char, and everything else → i32
                    emitExpression(out_, arg);
                    emitWritelnHostCall(out_, "__ctfe_write_i32");
                }
            }
        }
        
        // Emit newline at the end
        emitter.neededCTFEImports["__ctfe_write_newline"] = true;
        uint newlineIdx = emitter.getFuncIndex("__ctfe_write_newline");
        emitWasmCall(out_, newlineIdx);
    }

    /// If expression is an identifier referencing a string manifest constant, return it.
    private ManifestConstantDecl getStringManifest(Expression arg) {
        if (auto ident = cast(IdentifierExpression)arg) {
            auto symbol = emitter.symbolTable.lookupSymbol(ident.name);
            if (symbol && symbol.isConstant) {
                if (auto manifest = cast(ManifestConstantDecl)symbol.declaration) {
                    manifest.ensureEvaluated();
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
                uint funcIdx = emitter.getFuncIndex(importName, memberExpr.location);
                emitWasmCall(out_, funcIdx);
                return;
            }
        }

        // Handle extern(Objective-C) static method calls: NSApplication.sharedApplication()
        if (auto objIdent2 = cast(IdentifierExpression)memberExpr.object) {
            if (auto ifaceDecl = objIdent2.name in emitter.objcInterfaces) {
                emitObjCMethodCall(out_, *ifaceDecl, null, memberExpr.memberName, args, true);
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
                    uint funcIdx = emitter.getFuncIndex(method.mangledName, memberExpr.location);
                    emitWasmCall(out_, funcIdx);
                    return;
                }
            }
            throw new EmitError("Cannot resolve method '" ~ memberExpr.memberName ~ "' on nested member expression", memberExpr.location);
        }

        // Get the struct type from the object
        auto objIdent = cast(IdentifierExpression)memberExpr.object;
        if (!objIdent) {
            // Expression receiver: check type for method dispatch (enables chaining)
            if (memberExpr.object.type !is null) {
                auto resolved = memberExpr.object.type.resolve();
                if (auto ifaceDecl = resolved.asInterface()) {
                    if (ifaceDecl.isObjC) {
                        emitObjCMethodCall(out_, ifaceDecl, memberExpr.object, memberExpr.memberName, args, false);
                        return;
                    }
                }
                // ObjC class expression receiver: dispatch via synthetic interface
                if (auto classDecl2 = resolved.asClass()) {
                    if (classDecl2.isObjC) {
                        if (auto synthIface = classDecl2.name in emitter.objcInterfaces) {
                            emitObjCMethodCall(out_, *synthIface, memberExpr.object, memberExpr.memberName, args, false);
                            return;
                        }
                    }
                }
            }
            throw new EmitError("Method call on non-identifier object not yet supported", memberExpr.location);
        }

        // ObjC super call: super.method() inside an extern(Objective-C) class method
        if (objIdent.name == "super" && isObjCMethod && func.classParent !is null && func.classParent.isObjC) {
            emitObjCMsgSendSuper(out_, func.classParent, memberExpr.memberName, args);
            return;
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
                if (objInfo.ifaceDecl.isObjC) {
                    emitObjCMethodCall(out_, objInfo.ifaceDecl, memberExpr.object, memberExpr.memberName, args, false);
                } else {
                    emitInterfaceMethodCall(out_, objInfo, memberExpr.memberName, args);
                }
                return;
            }
        }

        // Find the struct or class declaration to look up the method
        StructDecl structDecl = null;
        ClassDecl classDecl = null;

        if (objInfo) {
            if (objInfo.isStruct) structDecl = objInfo.structDecl;
            else if (objInfo.isClass) {
                classDecl = objInfo.classDecl;
                // ObjC class: dispatch via objc_msgSend (same as ObjC interface)
                if (classDecl !is null && classDecl.isObjC) {
                    if (auto ifaceDecl = classDecl.name in emitter.objcInterfaces) {
                        emitObjCMethodCall(out_, *ifaceDecl, memberExpr.object, memberExpr.memberName, args, false);
                        return;
                    }
                }
            }
            // Auto-deref: pointer-to-struct/class variable
            else if (memberExpr.isAutoDereference) {
                auto aggDecl = resolvePointeeAggregate(memberExpr.object);
                if (auto sd = cast(StructDecl)aggDecl) structDecl = sd;
                else if (auto cd = cast(ClassDecl)aggDecl) classDecl = cd;
            }
        }

        if (!structDecl && !classDecl) {
            throw new EmitError("Cannot determine type for method call on " ~ objIdent.name, objIdent.location);
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
            throw new EmitError("Type '" ~ typeName ~ "' has no method '" ~ memberExpr.memberName ~ "'", memberExpr.location);
        }
        
        // Emit 'this' pointer as first argument (address of the instance)
        if (objInfo && (objInfo.isStruct || objInfo.isClass)) {
            emitVarAddress(out_, objInfo);
        } else if (memberExpr.isAutoDereference && objInfo) {
            // Pointer variable: its value IS the struct address
            emitLocalGet(out_, objInfo.wasmLocalIdx);
        }

        // Push hidden result pointer if method returns a large type (struct, array)
        bool methodHasLargeReturn = emitter.isLargeReturnType(method.returnType);
        uint methodResultTempSize = 0;
        if (methodHasLargeReturn) {
            methodResultTempSize = computeLargeReturnSize(method.returnType);
            assert(methodResultTempSize > 0, "emitMethodCall: large return size is 0 for method '" ~ method.name ~ "'");

            // Allocate temp on shadow stack for result
            emitGlobalGet(out_, emitter.spGlobal);
            emitI32Const(out_, methodResultTempSize);
            out_ ~= Op.i32_sub;
            emitGlobalSet(out_, emitter.spGlobal);

            // Push result pointer as hidden argument
            emitGlobalGet(out_, emitter.spGlobal);
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
            uint funcIdx = emitter.getFuncIndex(method.mangledName, memberExpr.location);
            emitWasmCall(out_, funcIdx);
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
                uint funcIdx = emitter.getFuncIndex(method.mangledName, memberExpr.location);
                emitWasmCall(out_, funcIdx);
            } else {
                // Virtual dispatch:
                // tableIndex = (vtable_ptr & TABLE_BASE_MASK) + methodSlot
                
                // Load vtable_ptr from object (at offset 0)
                if (objInfo && objInfo.isClass) {
                    emitVarAddress(out_, objInfo);
                    emitI32Load(out_);
                } else if (objInfo && memberExpr.isAutoDereference) {
                    // Pointer-to-class: pointer value IS the object address
                    emitLocalGet(out_, objInfo.wasmLocalIdx);
                    emitI32Load(out_);
                }
                
                // Mask to get tableBase: vtable_ptr & TABLE_BASE_MASK
                emitI32Const(out_, cast(int)WasmVtablePacking.TABLE_BASE_MASK);
                out_ ~= Op.i32_and;
                
                // Add method slot
                if (methodSlot > 0) {
                    emitI32Const(out_, methodSlot);
                    out_ ~= Op.i32_add;
                }
                
                // call_indirect with type signature
                uint funcIdx = emitter.getFuncIndex(method.mangledName, memberExpr.location);
                uint typeIdx = emitter.functions[funcIdx - cast(uint)emitter.imports.length].typeIndex;
                
                out_ ~= Op.call_indirect;
                leb128u(out_, typeIdx);  // type index
                leb128u(out_, 0);         // table index (always 0)
            }
        }

        // For large-return methods, leave result address on WASM stack
        if (methodHasLargeReturn) {
            emitGlobalGet(out_, emitter.spGlobal);
        }
    }

    /**
     * Emit super.method() via objc_msgSendSuper for D-defined ObjC classes (WASM path).
     * Builds objc_super {self, superclass} on shadow stack, calls through
     * a dedicated import bound to objc_msgSendSuper.
     */
    void emitObjCMsgSendSuper(ref Appender!(ubyte[]) out_, ClassDecl classDecl,
                               string methodName, Expression[] args) {
        // Find superclass name
        string superName = "NSObject";
        if (classDecl.interfaces.length > 0) {
            if (auto ut = cast(UserType) classDecl.interfaces[0])
                if (auto ifaceDecl = cast(InterfaceDecl) ut.declaration)
                    if (ifaceDecl.isObjC)
                        superName = ifaceDecl.name;
        }

        // Find method and selector
        FunctionDecl method = null;
        string selector = methodName;
        // Check parent interface
        if (classDecl.interfaces.length > 0) {
            if (auto ut = cast(UserType) classDecl.interfaces[0]) {
                if (auto ifaceDecl = cast(InterfaceDecl) ut.declaration) {
                    foreach (m; ifaceDecl.methods) {
                        if (m.name == methodName) {
                            method = m;
                            if (m.objcSelector !is null && m.objcSelector.length > 0)
                                selector = m.objcSelector;
                            break;
                        }
                    }
                }
            }
        }
        // Check own class methods
        if (method is null) {
            foreach (member; classDecl.members) {
                if (auto fd = cast(FunctionDecl)member) {
                    if (fd.name == methodName) {
                        method = fd;
                        if (fd.objcSelector !is null && fd.objcSelector.length > 0)
                            selector = fd.objcSelector;
                        break;
                    }
                }
            }
        }

        // Ensure __objc_msgSendSuper import exists
        emitter.ensureObjCMsgSendSuperImport();

        // Allocate 16 bytes on shadow stack for objc_super struct
        // SP -= 16
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 16);
        out_ ~= Op.i32_sub;
        emitGlobalSet(out_, emitter.spGlobal);

        // Store self (i64) at [SP+0]
        emitGlobalGet(out_, emitter.spGlobal);  // i32 address
        emitLocalGet(out_, 0);                  // self is local 0 (i64) in ObjC methods
        out_ ~= Op.i64_store;
        out_ ~= cast(ubyte) 0x03;  // align=8
        out_ ~= cast(ubyte) 0x00;  // offset=0

        // Store superclass (i64) at [SP+8]
        // Call objc_getClass(superName) → i64
        emitGlobalGet(out_, emitter.spGlobal);  // i32 address for store
        uint superNameAddr = emitter.registerCString(superName);
        emitI32Const(out_, superNameAddr);
        uint getClassIdx = emitter.getFuncIndex("objc_getClass", SourceLocation.init);
        emitWasmCall(out_, getClassIdx);        // → i64 superclass pointer
        out_ ~= Op.i64_store;
        out_ ~= cast(ubyte) 0x03;  // align=8
        out_ ~= cast(ubyte) 0x08;  // offset=8

        // Arg 1: pointer to objc_super struct (as i32 WASM memory offset — ARG_PTR converts to native)
        emitGlobalGet(out_, emitter.spGlobal);

        // Arg 2: selector (i64)
        uint selAddr = emitter.registerCString(selector);
        emitI32Const(out_, selAddr);
        uint selRegIdx = emitter.getFuncIndex("sel_registerName", SourceLocation.init);
        emitWasmCall(out_, selRegIdx);

        // Arg 3+: user arguments
        foreach (arg; args)
            emitExpression(out_, arg);

        // Call __objc_msgSendSuper
        uint superSendIdx = emitter.getFuncIndex("__objc_msgSendSuper", SourceLocation.init);
        emitWasmCall(out_, superSendIdx);

        // Restore shadow stack: SP += 16
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 16);
        out_ ~= Op.i32_add;
        emitGlobalSet(out_, emitter.spGlobal);
    }

    /**
     * Emit extern(Objective-C) method call.
     * Lowers to: objc_msgSend(receiver, sel_registerName("selector"), args...)
     *
     * For struct returns: allocates shadow stack temp, passes result pointer
     * as hidden arg after receiver+selector, leaves result address on stack.
     */
    void emitObjCMethodCall(ref Appender!(ubyte[]) out_, InterfaceDecl ifaceDecl,
                            Expression receiverExpr, string methodName,
                            Expression[] args, bool isStaticCall) {
        // Find the method in the interface
        FunctionDecl method = null;
        foreach (m; ifaceDecl.methods) {
            if (m.name == methodName) {
                method = m;
                break;
            }
        }
        if (method is null)
            throw new EmitError("ObjC interface " ~ ifaceDecl.name ~ " has no method " ~ methodName,
                               SourceLocation.init);

        string selector = method.objcSelector;
        if (selector is null) selector = method.name;

        // Detect struct return
        auto resolvedRet = method.returnType.resolve();
        StructDecl retStructDecl = resolvedRet.asStruct();
        bool isStructReturn = retStructDecl !is null;
        uint structRetSize = 0;

        // For struct returns: allocate shadow stack temp and save address
        if (isStructReturn) {
            assert(retStructDecl.layoutComputed,
                "ObjC struct return " ~ retStructDecl.name ~ ": layout not computed");
            structRetSize = cast(uint)retStructDecl.aggregateSize_;

            // SP -= structRetSize
            emitGlobalGet(out_, emitter.spGlobal);
            emitI32Const(out_, structRetSize);
            out_ ~= Op.i32_sub;
            emitGlobalSet(out_, emitter.spGlobal);

            // Save result address to tempLocalA
            emitGlobalGet(out_, emitter.spGlobal);
            emitLocalSet(out_, tempLocalA);
        }

        // Arg 1: receiver (i64)
        if (isStaticCall) {
            // Push class name string pointer, call objc_getClass -> returns i64
            uint classNameAddr = emitter.registerCString(ifaceDecl.name);
            emitI32Const(out_, classNameAddr);
            uint getClassIdx = emitter.getFuncIndex("objc_getClass", method.location);
            emitWasmCall(out_, getClassIdx);
        } else {
            // Push the receiver expression (already an i64 value)
            emitExpression(out_, receiverExpr);
        }

        // Arg 2: selector (i64)
        uint selAddr = emitter.registerCString(selector);
        emitI32Const(out_, selAddr);
        uint selRegIdx = emitter.getFuncIndex("sel_registerName", method.location);
        emitWasmCall(out_, selRegIdx);

        // Arg 3 (struct return only): result pointer (i32)
        if (isStructReturn) {
            emitLocalGet(out_, tempLocalA);
        }

        // Remaining args: user arguments (with i32→i64 promotion where needed)
        foreach (i, arg; args) {
            if (i < method.parameters.length) {
                auto paramType = method.parameters[i].type.resolve();
                if (auto structDecl = paramType.asStruct()) {
                    // Struct arg: emit address, save to temp, load each field individually
                    assert(structDecl.fields.length > 0,
                        "ObjC call: struct " ~ structDecl.name ~ " has no fields at emission time");
                    emitExpression(out_, arg);  // pushes i32 address
                    emitLocalSet(out_, tempLocalB);
                    foreach (field; structDecl.fields) {
                        emitLocalGet(out_, tempLocalB);
                        if (field.offset > 0) {
                            emitI32Const(out_, cast(int)field.offset);
                            out_ ~= Op.i32_add;
                        }
                        auto bt = cast(BasicType)field.type;
                        bool isFloat = bt && (bt.kind == BasicType.Kind.Float64 || bt.kind == BasicType.Kind.Float32);
                        emitLoadForSize(out_, cast(uint)field.size, isFloat);
                    }
                    continue;  // skip normal emit path
                }
            }
            emitExpression(out_, arg);
            if (i < method.parameters.length) {
                ValType expected = emitter.dTypeToValType(method.parameters[i].type);
                if (expected == ValType.i64 && !isI64Expression(arg)) {
                    out_ ~= Op.i64_extend_i32_s;
                }
                if (expected == ValType.f64 && !isF64Expression(arg)) {
                    out_ ~= Op.f64_convert_i32_s;
                }
            }
        }

        // Call __objc_send_<Interface>_<method>
        string importName = method.mangledName;
        uint funcIdx = emitter.getFuncIndex(importName, method.location);
        emitWasmCall(out_, funcIdx);

        // For struct returns: push result address (trampoline wrote struct to shadow stack)
        if (isStructReturn) {
            emitLocalGet(out_, tempLocalA);
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
            throw new EmitError("Interface " ~ ifaceDecl.name ~ " has no method " ~ methodName, SourceLocation.init);
        }

        // Emit obj_ptr as 'this' argument
        if (ifaceInfo.addrMode == AddrMode.shadowStack) {
            // Local interface: fat pointer on shadow stack — load obj_ptr from offset 0
            emitFPOffset(out_, ifaceInfo.frameOffset);
            emitI32Load(out_);
        } else {
            // Param interface: obj_ptr is a WASM local
            emitLocalGet(out_, ifaceInfo.wasmLocalIdx);
        }

        // Emit other arguments
        foreach (arg; args) {
            emitExpression(out_, arg);
        }

        // Load itable_ptr
        if (ifaceInfo.addrMode == AddrMode.shadowStack) {
            // Local: load from fat pointer at ITABLE_OFFSET
            emitFPOffset(out_, ifaceInfo.frameOffset + WasmFatPointerLayout.ITABLE_OFFSET);
            emitI32Load(out_);
        } else {
            // Param: itable is in a separate WASM local
            emitLocalGet(out_, ifaceInfo.itableLocalIdx);
        }

        // Extract itableBase (lower bits via TABLE_BASE_MASK)
        emitI32Const(out_, cast(int)WasmVtablePacking.TABLE_BASE_MASK);
        out_ ~= Op.i32_and;

        // Add method slot to get final table index
        if (methodSlot > 0) {
            emitI32Const(out_, methodSlot);
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
        uint funcIdx = emitter.getFuncIndex(memberExpr.memberName, memberExpr.location);
        emitWasmCall(out_, funcIdx);
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
                              Expression[] args, int resultFrameOffset,
                              SourceLocation loc = SourceLocation.init) {
        assert(frameSize > 0, "emitStructReturnCall requires a shadow stack frame (frameSize > 0)");
        assert(funcName.length > 0, "emitStructReturnCall: empty function name");
        // Push hidden result pointer as first argument: FP + resultFrameOffset
        emitLocalGet(out_, fpLocal);
        if (resultFrameOffset != 0) {
            emitI32Const(out_, resultFrameOffset);
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
                    emitGlobalGet(out_, emitter.spGlobal);
                    emitI32Const(out_, structSize);
                    out_ ~= Op.i32_sub;
                    emitGlobalSet(out_, emitter.spGlobal);

                    // Copy fields from source to temp (type-aware blit)
                    foreach (field; argStructDecl.fields) {
                        auto fbt = cast(BasicType)field.type;
                        bool fIsFloat = fbt && (fbt.kind == BasicType.Kind.Float64 || fbt.kind == BasicType.Kind.Float32);
                        uint fSize = cast(uint)field.size;

                        emitGlobalGet(out_, emitter.spGlobal);
                        if (field.offset > 0) {
                            emitI32Const(out_, cast(int)field.offset);
                            out_ ~= Op.i32_add;
                        }
                        emitVarAddress(out_, argInfo);
                        if (field.offset > 0) {
                            emitI32Const(out_, cast(int)field.offset);
                            out_ ~= Op.i32_add;
                        }
                        emitLoadForSize(out_, fSize, fIsFloat);
                        emitStoreForSize(out_, fSize, fIsFloat);
                    }

                    emitGlobalGet(out_, emitter.spGlobal);
                    totalCopySize += structSize;
                    continue;
                }
            }

            // Non-aggregate argument
            emitExpression(out_, arg);
        }

        // Call
        uint funcIdx = emitter.getFuncIndex(funcName, loc);
        emitWasmCall(out_, funcIdx);

        // Deallocate arg copies (not the result — that lives in the caller's frame)
        if (totalCopySize > 0) {
            emitGlobalGet(out_, emitter.spGlobal);
            emitI32Const(out_, totalCopySize);
            out_ ~= Op.i32_add;
            emitGlobalSet(out_, emitter.spGlobal);
        }
    }

    /**
     * Emit a method call that returns an aggregate via hidden result pointer,
     * writing directly into the caller's frame at resultFrameOffset.
     * Used for: Point p = s.origin();
     */
    void emitStructReturnMethodCall(ref Appender!(ubyte[]) out_, MemberExpression memberExpr,
                                     Expression[] args, int resultFrameOffset) {
        assert(frameSize > 0, "emitStructReturnMethodCall requires a shadow stack frame (frameSize > 0)");

        // Resolve object and method (same logic as emitMethodCall)
        auto objIdent = cast(IdentifierExpression)memberExpr.object;
        if (!objIdent)
            throw new EmitError("Struct-returning method call on non-identifier object not yet supported", memberExpr.location);

        auto objInfo = resolveVar(objIdent.resolvedLocalId, objIdent.name);
        if (!objInfo)
            throw new EmitError("Unknown variable for struct-returning method call: " ~ objIdent.name, objIdent.location);

        StructDecl structDecl = null;
        ClassDecl classDecl = null;
        if (objInfo.isStruct) structDecl = objInfo.structDecl;
        else if (objInfo.isClass) classDecl = objInfo.classDecl;
        if (!structDecl && !classDecl)
            throw new EmitError("Cannot determine type for struct-returning method call on " ~ objIdent.name, objIdent.location);

        // Find the method
        FunctionDecl method = null;
        if (structDecl) {
            foreach (member; structDecl.members)
                if (auto fd = cast(FunctionDecl)member)
                    if (fd.name == memberExpr.memberName && fd.isMethod) { method = fd; break; }
        } else if (classDecl) {
            ClassDecl current = classDecl;
            while (current && !method) {
                foreach (member; current.members)
                    if (auto fd = cast(FunctionDecl)member)
                        if (fd.name == memberExpr.memberName && fd.isMethod) { method = fd; break; }
                current = current.baseClassDecl;
            }
        }
        if (!method)
            throw new EmitError("No method '" ~ memberExpr.memberName ~ "' for struct-returning call", memberExpr.location);

        assert(emitter.isLargeReturnType(method.returnType),
            "emitStructReturnMethodCall called for non-large-return method '" ~ method.name ~ "'");
        assert(method.mangledName !is null && method.mangledName.length > 0,
            "emitStructReturnMethodCall: method '" ~ method.name ~ "' has no mangled name");

        // --- Push arguments in canonical order: [this, result_ptr, arena?, user_args] ---

        // 1. this pointer
        emitVarAddress(out_, objInfo);

        // 2. result_ptr: FP + resultFrameOffset (write directly into caller's local)
        emitLocalGet(out_, fpLocal);
        if (resultFrameOffset != 0) {
            emitI32Const(out_, resultFrameOffset);
            out_ ~= Op.i32_add;
        }

        // 3. arena pointer if needed
        if (method.needsArena)
            emitArenaPointer(out_);

        // 4. user arguments
        foreach (arg; args)
            emitExpression(out_, arg);

        // --- Dispatch: direct call or virtual ---
        if (structDecl) {
            uint funcIdx = emitter.getFuncIndex(method.mangledName, memberExpr.location);
            emitWasmCall(out_, funcIdx);
        } else if (classDecl) {
            assert(classDecl.virtualMethods !is null,
                "emitStructReturnMethodCall: class '" ~ classDecl.name ~ "' has no virtualMethods");
            int methodSlot = -1;
            foreach (i, vm; classDecl.virtualMethods)
                if (vm.name == method.name) { methodSlot = cast(int)i; break; }

            if (methodSlot < 0) {
                uint funcIdx = emitter.getFuncIndex(method.mangledName, memberExpr.location);
                emitWasmCall(out_, funcIdx);
            } else {
                // Virtual dispatch: load vtable_ptr, mask, add slot, call_indirect
                emitVarAddress(out_, objInfo);
                emitI32Load(out_);

                emitI32Const(out_, cast(int)WasmVtablePacking.TABLE_BASE_MASK);
                out_ ~= Op.i32_and;

                if (methodSlot > 0) {
                    emitI32Const(out_, methodSlot);
                    out_ ~= Op.i32_add;
                }

                uint funcIdx = emitter.getFuncIndex(method.mangledName, memberExpr.location);
                assert(funcIdx >= emitter.imports.length,
                    "emitStructReturnMethodCall: method funcIdx is an import, not a user function");
                uint typeIdx = emitter.functions[funcIdx - cast(uint)emitter.imports.length].typeIndex;
                out_ ~= Op.call_indirect;
                leb128u(out_, typeIdx);
                leb128u(out_, 0);
            }
        }
        // No need to push result address — callee wrote directly into our frame
    }

    /**
     * Emit struct construction to a temporary on shadow stack.
     * Leaves pointer to the struct on the value stack.
     */
    void emitStructConstructionToTemp(ref Appender!(ubyte[]) out_, StructDecl structDecl, Expression[] args) {
        uint structSize = cast(uint)structDecl.structSize;
        
        // Allocate space: SP = SP - structSize
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, structSize);
        out_ ~= Op.i32_sub;
        emitGlobalSet(out_, emitter.spGlobal);
        
        // Initialize at base address = current SP
        emitStructFieldsInit(out_, structDecl, args, EmitAddrMode.fromSP, 0);
        
        // Leave pointer to struct on stack
        emitGlobalGet(out_, emitter.spGlobal);
    }
    
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
                        emitLocalGet(out_, fpLocal);
                    } else {
                        emitGlobalGet(out_, emitter.spGlobal);
                    }
                    int destOff = fieldAddr + cast(int)off;
                    if (destOff != 0) {
                        emitI32Const(out_, destOff);
                        out_ ~= Op.i32_add;
                    }
                    
                    // Load from source: duplicate src_addr, add offset, load
                    emitExpression(out_, args[i]);  // Stack: [dest_addr, src_addr]
                    if (off != 0) {
                        emitI32Const(out_, cast(int)off);
                        out_ ~= Op.i32_add;
                    }
                    emitI32Load(out_);
                    
                    // Store to destination: Stack: [dest_addr, value]
                    emitI32Store(out_);
                }
                continue;
            }
            
            // Emit destination address based on mode
            if (baseMode == EmitAddrMode.fromFP) {
                emitLocalGet(out_, fpLocal);
            } else {
                emitGlobalGet(out_, emitter.spGlobal);
            }
            if (fieldAddr != 0) {
                emitI32Const(out_, fieldAddr);
                out_ ~= Op.i32_add;
            }
            
            // Emit value
            emitExpression(out_, args[i]);

            // Store
            auto bt = cast(BasicType)field.type;
            bool isFloat = bt && (bt.kind == BasicType.Kind.Float64 || bt.kind == BasicType.Kind.Float32);
            emitStoreForSize(out_, cast(uint)field.size, isFloat);
        }
    }


}
