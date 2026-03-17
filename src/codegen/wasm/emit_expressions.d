/**
 * ExpressionEmitter — mixin for FuncContext
 * Auto-extracted from func_context.d
 */
module codegen.wasm.emit_expressions;

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

mixin template ExpressionEmitter() {
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
            // Check for exception after real function calls (not struct/class construction)
            if (!isConstructionCall(call)) {
                if (expressionHasValue(call))
                    emitExceptionCheckWithValue(out_, call.location, isI64Expression(call), isF64Expression(call), isF32Expression(call));
                else
                    emitExceptionCheck(out_, call.location);
            }
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
            emitI32Const(out_, traits.boolResult ? 1 : 0);
        } else if (auto isExpr = cast(IsExpression)expr) {
            emitI32Const(out_, isExpr.boolResult ? 1 : 0);
        } else if (auto tmplInst = cast(TemplateInstantiationExpression)expr) {
            emitTemplateCall(out_, tmplInst);
            // Check for exception after real template function calls (not struct construction)
            if (!tmplInst.resolvedStructInstantiation) {
                if (expressionHasValue(tmplInst))
                    emitExceptionCheckWithValue(out_, tmplInst.location, isI64Expression(tmplInst), isF64Expression(tmplInst));
                else
                    emitExceptionCheck(out_, tmplInst.location);
            }
        } else if (auto newExpr = cast(NewExpression)expr) {
            emitNewExpression(out_, newExpr);
        } else if (auto funcLit = cast(FunctionLiteralExpression)expr) {
            emitFunctionLiteral(out_, funcLit);
        } else if (auto throwExpr = cast(ThrowExpression)expr) {
            emitThrowExpression(out_, throwExpr);
        } else {
            throw new EmitError("Unsupported expression type", expr.location);
        }
    }
    
    void emitIndex(ref Appender!(ubyte[]) out_, IndexExpression expr) {
        // Pointer indexing: p[i] = *(p + i * elemSize)
        if (auto ptrType = cast(PointerType)(expr.array.type ? expr.array.type.resolve() : null)) {
            emitExpression(out_, expr.array);
            uint elemSize = wasmElementSize(ptrType.pointeeType);
            emitExpression(out_, expr.index);
            emitI32Const(out_, elemSize);
            out_ ~= Op.i32_mul;
            out_ ~= Op.i32_add;
            bool isFloat = isF64ElementType(ptrType.pointeeType) || isF32ElementType(ptrType.pointeeType);
            if (elemSize <= 4 || isFloat)
                emitLoadForSize(out_, elemSize, isFloat);
            return;
        }

        // Check if this uses the intrinsic opIndex path
        if (expr.usesOpIndex && expr.opIndexMethod && expr.opIndexMethod.isIntrinsic) {
            emitIntrinsicOpIndex(out_, expr);
            return;
        }
        
        // Non-intrinsic opIndex would emit a method call here
        // (not yet implemented - would call user-defined opIndex)
        
        throw new EmitError("Non-intrinsic indexing not yet supported", expr.location);
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
                    emitI32Load(out_);
                    // Add index * elemSize
                    uint elemSize = wasmElementSize(arrType.elementType);
                    emitExpression(out_, expr.index);
                    emitI32Const(out_, elemSize);
                    out_ ~= Op.i32_mul;
                    out_ ~= Op.i32_add;
                    // Load value for scalar elements
                    bool isFloat = isF64ElementType(arrType.elementType) || isF32ElementType(arrType.elementType);
                    if (elemSize <= 4 || isFloat)
                        emitLoadForSize(out_, elemSize, isFloat);
                    return;
                }
            }
            throw new EmitError("Cannot index member expression of non-slice type", memberExpr.location);
        }

        // Get the array identifier
        auto arrayIdent = cast(IdentifierExpression)expr.array;
        if (!arrayIdent) {
            throw new EmitError("Complex array indexing not yet supported", expr.location);
        }
        
        // Unified variable lookup
        if (auto info = resolveVar(arrayIdent.resolvedLocalId, arrayIdent.name)) {
            if (info.isStaticArray) {
                // Static array: base address + index * elemSize
                emitVarAddress(out_, info);
                emitExpression(out_, expr.index);
                emitI32Const(out_, info.elementSize);
                out_ ~= Op.i32_mul;
                out_ ~= Op.i32_add;
                // Aggregate elements: leave address on stack (like struct variables)
                {
                    bool isFloat = isF64ElementType(info.elementType) || isF32ElementType(info.elementType);
                    if (info.elementSize <= 4 || isFloat)
                        emitLoadForSize(out_, info.elementSize, isFloat);
                }
                return;
            } else if (info.isSlice) {
                // Load ptr from slice struct (offset 0), then add index * elemSize
                emitVarAddress(out_, info);
                emitI32Load(out_);
                emitExpression(out_, expr.index);
                emitI32Const(out_, info.elementSize);
                out_ ~= Op.i32_mul;
                out_ ~= Op.i32_add;
                // Aggregate elements: leave address on stack (like struct variables)
                {
                    bool isFloat = isF64ElementType(info.elementType) || isF32ElementType(info.elementType);
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
                            emitLocalGet(out_, thisInfo.wasmLocalIdx);
                            if (field.offset > 0) {
                                emitI32Const(out_, cast(int)field.offset);
                                out_ ~= Op.i32_add;
                            }
                            emitI32Load(out_);
                            // Add index * elemSize
                            emitExpression(out_, expr.index);
                            emitI32Const(out_, elemSize);
                            out_ ~= Op.i32_mul;
                            out_ ~= Op.i32_add;
                            // Load value for scalar elements
                            bool isFloat = isF64ElementType(arrType.elementType) || isF32ElementType(arrType.elementType);
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
                    emitI32Const(out_, structAddr);
                    emitI32Load(out_);
                    
                    // Calculate address: ptr + index * elemSize
                    emitExpression(out_, expr.index);
                    emitI32Const(out_, elemSize);
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
                        emitI32Load(out_);
                    }
                    return;
                }
            }
        }
        
        throw new EmitError("Unsupported array indexing on " ~ arrayIdent.name, arrayIdent.location);
    }
    
    /**
     * Emit index assignment for arrays - arr[i] = value
     */
    void emitIndexAssignment(ref Appender!(ubyte[]) out_, IndexExpression indexExpr, Expression value) {
        // Pointer index assignment: p[i] = value
        if (auto ptrType = cast(PointerType)(indexExpr.array.type ? indexExpr.array.type.resolve() : null)) {
            emitExpression(out_, indexExpr.array);
            uint elemSize = wasmElementSize(ptrType.pointeeType);
            emitExpression(out_, indexExpr.index);
            emitI32Const(out_, elemSize);
            out_ ~= Op.i32_mul;
            out_ ~= Op.i32_add;
            emitExpression(out_, value);
            bool isFloat = isF64ElementType(ptrType.pointeeType) || isF32ElementType(ptrType.pointeeType);
            if (isF32ElementType(ptrType.pointeeType) && isF64Expression(value))
                out_ ~= Op.f32_demote_f64;
            emitStoreForSize(out_, elemSize, isFloat);
            // Leave assigned value on stack
            emitExpression(out_, value);
            if (isF32ElementType(ptrType.pointeeType) && isF64Expression(value))
                out_ ~= Op.f32_demote_f64;
            return;
        }

        // Handle member expression as array source (e.g., s.data[i] = value)
        if (auto memberExpr = cast(MemberExpression)indexExpr.array) {
            auto memberType = getMemberExpressionType(memberExpr);
            if (auto arrType = cast(ArrayType)memberType) {
                if (!arrType.isStaticArray) {
                    uint elemSize = wasmElementSize(arrType.elementType);
                    // Emit address of slice struct, load ptr
                    emitMember(out_, memberExpr);
                    emitI32Load(out_);
                    // Add index * elemSize
                    emitExpression(out_, indexExpr.index);
                    emitI32Const(out_, elemSize);
                    out_ ~= Op.i32_mul;
                    out_ ~= Op.i32_add;
                    // Store value
                    emitExpression(out_, value);
                    bool isFloatElem = isF64ElementType(arrType.elementType) || isF32ElementType(arrType.elementType);
                    if (isF32ElementType(arrType.elementType) && isF64Expression(value))
                        out_ ~= Op.f32_demote_f64;
                    emitStoreForSize(out_, elemSize, isFloatElem);
                    // Leave assigned value on stack (assignment is an expression)
                    emitExpression(out_, value);
                    if (isF32ElementType(arrType.elementType) && isF64Expression(value))
                        out_ ~= Op.f32_demote_f64;
                    return;
                }
            }
            throw new EmitError("Cannot index-assign member expression of non-slice type", memberExpr.location);
        }

        // Get the array identifier
        auto arrayIdent = cast(IdentifierExpression)indexExpr.array;
        if (!arrayIdent) {
            throw new EmitError("Complex array index assignment not yet supported", indexExpr.location);
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
                    emitI32Load(out_);
                }
                emitExpression(out_, indexExpr.index);
                emitI32Const(out_, info.elementSize);
                out_ ~= Op.i32_mul;
                out_ ~= Op.i32_add;

                if (info.elementSize > 4) {
                    // Aggregate element: copy elementSize bytes from src to dst
                    emitLocalSet(out_, tempLocalA);
                    emitExpression(out_, value);  // src addr (aggregate convention)
                    emitLocalSet(out_, tempLocalB);
                    // Copy 4 bytes at a time
                    for (uint offset = 0; offset < info.elementSize; offset += 4) {
                        emitLocalGet(out_, tempLocalA);
                        if (offset > 0) {
                            emitI32Const(out_, offset);
                            out_ ~= Op.i32_add;
                        }
                        emitLocalGet(out_, tempLocalB);
                        if (offset > 0) {
                            emitI32Const(out_, offset);
                            out_ ~= Op.i32_add;
                        }
                        emitI32Load(out_);
                        emitI32Store(out_);
                    }
                    // Expression value: push dst addr
                    emitLocalGet(out_, tempLocalA);
                } else {
                    // Scalar element: simple store
                    emitExpression(out_, value);
                    bool isFloatElem = isF64ElementType(info.elementType) || isF32ElementType(info.elementType);
                    // Implicit f64→f32 demotion for float array elements
                    if (isF32ElementType(info.elementType) && isF64Expression(value))
                        out_ ~= Op.f32_demote_f64;
                    emitStoreForSize(out_, info.elementSize, isFloatElem);
                    // Leave assigned value on stack (assignment is an expression)
                    emitExpression(out_, value);
                    if (isF32ElementType(info.elementType) && isF64Expression(value))
                        out_ ~= Op.f32_demote_f64;
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
                            emitLocalGet(out_, thisInfo.wasmLocalIdx);
                            if (field.offset > 0) {
                                emitI32Const(out_, cast(int)field.offset);
                                out_ ~= Op.i32_add;
                            }
                            emitI32Load(out_);
                            // Add index * elemSize
                            emitExpression(out_, indexExpr.index);
                            emitI32Const(out_, elemSize);
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

        throw new EmitError("Unsupported array index assignment on " ~ arrayIdent.name, arrayIdent.location);
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
        
        throw new EmitError("Unknown slice method: " ~ methodName, SourceLocation.init);
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
            throw new EmitError("reserve() requires exactly 1 argument", SourceLocation.init);
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
        emitFPOffset(out_, sliceAddr + sliceLayout.capacityOffset);
        emitI32Load(out_);
        
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
        emitI32Const(out_, 4);
        out_ ~= Op.i32_mul;

        // Call __arena_alloc
        uint allocIdx = emitter.getFuncIndex("__arena_alloc");
        emitWasmCall(out_, allocIdx);
        // Stack: [newBuffer]

        // Store newBuffer in a temp location (use SP - 4)
        // Save return value to temp local first (i32.store needs [addr, val] order)
        emitLocalSet(out_, tempLocalA);
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 4);
        out_ ~= Op.i32_sub;
        emitLocalGet(out_, tempLocalA);
        // Stack: [SP-4, newBuffer]
        emitI32Store(out_);
        
        // Copy loop: for i = 0 to length-1, copy element
        // We'll use a simple loop with block/loop/br_if
        
        // Initialize loop counter at SP-8
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 8);
        out_ ~= Op.i32_sub;
        emitI32Const(out_, 0);
        emitI32Store(out_);
        
        // block $break
        out_ ~= Op.block;
        out_ ~= cast(ubyte)0x40;  // void
        
        // loop $continue
        out_ ~= Op.loop;
        out_ ~= cast(ubyte)0x40;  // void
        
        // Check: if (i >= length) break
        // Load i
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 8);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        
        // Load length
        emitFPOffset(out_, sliceAddr + sliceLayout.lengthOffset);
        emitI32Load(out_);
        
        // if i >= length, break
        out_ ~= Op.i32_ge_u;
        emitBrIf(out_, 1);
        
        // Copy element: newBuffer[i] = oldPtr[i]
        // Dest address: newBuffer + i * 4
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 4);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 8);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        
        emitI32Const(out_, 4);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;  // newBuffer + i*4
        
        // Load from old ptr[i]
        emitFPOffset(out_, sliceAddr);
        emitI32Load(out_);
        
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 8);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        
        emitI32Const(out_, 4);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;  // oldPtr + i*4
        
        emitI32Load(out_);
        
        // Store to newBuffer[i]
        emitI32Store(out_);
        
        // Increment i
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 8);
        out_ ~= Op.i32_sub;
        // Load i, add 1, store back
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 8);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitI32Const(out_, 1);
        out_ ~= Op.i32_add;
        emitI32Store(out_);
        
        // Continue loop
        emitBr(out_, 0);
        
        out_ ~= Op.end;  // end loop
        out_ ~= Op.end;  // end block
        
        // Update slice.ptr = newBuffer
        emitFPOffset(out_, sliceAddr);
        
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 4);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        
        emitI32Store(out_);
        
        // Update slice.capacity = newCapacity
        emitFPOffset(out_, sliceAddr + sliceLayout.capacityOffset);
        
        emitExpression(out_, args[0]);  // newCapacity
        
        emitI32Store(out_);
        
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
        bool isFloat = isF64ElementType(sliceInfo.elementType) || isF32ElementType(sliceInfo.elementType);
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
            emitLocalSet(out_, tempLocalA);
            for (uint w = 0; w < elementSize; w += 4) {
                // dest = SP - valSize + w
                emitGlobalGet(out_, emitter.spGlobal);
                emitI32Const(out_, valSize - w);
                out_ ~= Op.i32_sub;
                // src = tempLocalA + w
                emitLocalGet(out_, tempLocalA);
                if (w > 0) {
                    emitI32Const(out_, w);
                    out_ ~= Op.i32_add;
                }
                emitI32Load(out_);
                // store
                emitI32Store(out_);
            }
        } else {
            emitGlobalGet(out_, emitter.spGlobal);
            emitI32Const(out_, valSize);
            out_ ~= Op.i32_sub;
            emitExpression(out_, value);
            if (isFloat) {
                out_ ~= Op.f64_store;
                out_ ~= cast(ubyte)0x03;  // alignment log2(8)
                leb128u(out_, 0);
            } else {
                emitI32Store(out_);
            }
        }

        // Check if length >= capacity
        emitFPOffset(out_, sliceAddr + sliceLayout.lengthOffset);
        emitI32Load(out_);

        emitFPOffset(out_, sliceAddr + sliceLayout.capacityOffset);
        emitI32Load(out_);

        out_ ~= Op.i32_ge_u;  // length >= capacity

        out_ ~= Op.if_;
        out_ ~= cast(ubyte)0x40;

        // Need to grow: newCapacity = max(capacity * 2, 4)
        // Store newCapacity at SP-capOff
        // First push the destination address
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, capOff);
        out_ ~= Op.i32_sub;

        // Calculate capacity * 2
        emitFPOffset(out_, sliceAddr + sliceLayout.capacityOffset);
        emitI32Load(out_);
        emitI32Const(out_, 2);
        out_ ~= Op.i32_mul;

        // Compare with 4, take max
        emitI32Const(out_, 4);

        // if (capacity*2 < 4) use 4 else use capacity*2
        emitFPOffset(out_, sliceAddr + sliceLayout.capacityOffset);
        emitI32Load(out_);
        emitI32Const(out_, 2);
        out_ ~= Op.i32_mul;
        emitI32Const(out_, 4);
        emitUnsignedMaxSelect(out_);  // max(capacity*2, 4)

        // Now stack has [SP-capOff, newCapacity], store
        emitI32Store(out_);

        // Allocate new buffer via arena
        emitArenaPointer(out_);
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, capOff);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitI32Const(out_, sliceInfo.elementSize);
        out_ ~= Op.i32_mul;
        uint allocIdx = emitter.getFuncIndex("__arena_alloc");
        emitWasmCall(out_, allocIdx);

        // Store newBuffer at SP-bufOff
        // Save return value to temp local first (i32.store needs [addr, val] order)
        emitLocalSet(out_, tempLocalA);
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, bufOff);
        out_ ~= Op.i32_sub;
        emitLocalGet(out_, tempLocalA);
        // Stack: [SP-bufOff, newBuffer]
        emitI32Store(out_);

        // Copy loop: i = 0
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, ctrOff);
        out_ ~= Op.i32_sub;
        emitI32Const(out_, 0);
        emitI32Store(out_);

        out_ ~= Op.block;
        out_ ~= cast(ubyte)0x40;
        out_ ~= Op.loop;
        out_ ~= cast(ubyte)0x40;

        // if i >= length break
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, ctrOff);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitFPOffset(out_, sliceAddr + sliceLayout.lengthOffset);
        emitI32Load(out_);
        out_ ~= Op.i32_ge_u;
        emitBrIf(out_, 1);

        // newBuffer[i] = oldPtr[i]
        if (isAggregate) {
            // Compute dest address: newBuffer + i * elementSize → tempLocalA
            emitGlobalGet(out_, emitter.spGlobal);
            emitI32Const(out_, bufOff);
            out_ ~= Op.i32_sub;
            emitI32Load(out_);
            emitGlobalGet(out_, emitter.spGlobal);
            emitI32Const(out_, ctrOff);
            out_ ~= Op.i32_sub;
            emitI32Load(out_);
            emitI32Const(out_, elementSize);
            out_ ~= Op.i32_mul;
            out_ ~= Op.i32_add;
            emitLocalSet(out_, tempLocalA);

            // Compute source address: oldPtr + i * elementSize → tempLocalB
            emitFPOffset(out_, sliceAddr);
            emitI32Load(out_);
            emitGlobalGet(out_, emitter.spGlobal);
            emitI32Const(out_, ctrOff);
            out_ ~= Op.i32_sub;
            emitI32Load(out_);
            emitI32Const(out_, elementSize);
            out_ ~= Op.i32_mul;
            out_ ~= Op.i32_add;
            emitLocalSet(out_, tempLocalB);

            // Word-by-word copy
            for (uint w = 0; w < elementSize; w += 4) {
                emitLocalGet(out_, tempLocalA);
                if (w > 0) {
                    emitI32Const(out_, w);
                    out_ ~= Op.i32_add;
                }
                emitLocalGet(out_, tempLocalB);
                if (w > 0) {
                    emitI32Const(out_, w);
                    out_ ~= Op.i32_add;
                }
                emitI32Load(out_);
                emitI32Store(out_);
            }
        } else {
            // Scalar copy: dest address on stack, load source, store
            emitGlobalGet(out_, emitter.spGlobal);
            emitI32Const(out_, bufOff);
            out_ ~= Op.i32_sub;
            emitI32Load(out_);
            emitGlobalGet(out_, emitter.spGlobal);
            emitI32Const(out_, ctrOff);
            out_ ~= Op.i32_sub;
            emitI32Load(out_);
            emitI32Const(out_, elementSize);
            out_ ~= Op.i32_mul;
            out_ ~= Op.i32_add;

            emitFPOffset(out_, sliceAddr);
            emitI32Load(out_);
            emitGlobalGet(out_, emitter.spGlobal);
            emitI32Const(out_, ctrOff);
            out_ ~= Op.i32_sub;
            emitI32Load(out_);
            emitI32Const(out_, elementSize);
            out_ ~= Op.i32_mul;
            out_ ~= Op.i32_add;
            emitLoadForSize(out_, elementSize, isFloat);

            emitStoreForSize(out_, elementSize, isFloat);
        }

        // i++
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, ctrOff);
        out_ ~= Op.i32_sub;
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, ctrOff);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitI32Const(out_, 1);
        out_ ~= Op.i32_add;
        emitI32Store(out_);

        emitBr(out_, 0);
        out_ ~= Op.end;
        out_ ~= Op.end;

        // Update ptr
        emitFPOffset(out_, sliceAddr);
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, bufOff);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitI32Store(out_);

        // Update capacity
        emitFPOffset(out_, sliceAddr + sliceLayout.capacityOffset);
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, capOff);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitI32Store(out_);

        out_ ~= Op.end;  // end if (need grow)

        // Store value at ptr[length]
        if (isAggregate) {
            // Compute dest address: ptr + length * elementSize → tempLocalA
            emitFPOffset(out_, sliceAddr);
            emitI32Load(out_);
            emitFPOffset(out_, sliceAddr + sliceLayout.lengthOffset);
            emitI32Load(out_);
            emitI32Const(out_, elementSize);
            out_ ~= Op.i32_mul;
            out_ ~= Op.i32_add;
            emitLocalSet(out_, tempLocalA);

            // Word-by-word copy from scratch area to destination
            for (uint w = 0; w < elementSize; w += 4) {
                // dest word
                emitLocalGet(out_, tempLocalA);
                if (w > 0) {
                    emitI32Const(out_, w);
                    out_ ~= Op.i32_add;
                }
                // source word from scratch
                emitGlobalGet(out_, emitter.spGlobal);
                emitI32Const(out_, valSize - w);
                out_ ~= Op.i32_sub;
                emitI32Load(out_);
                // store
                emitI32Store(out_);
            }
        } else {
            // Scalar: compute dest, load from scratch, store
            emitFPOffset(out_, sliceAddr);
            emitI32Load(out_);
            emitFPOffset(out_, sliceAddr + sliceLayout.lengthOffset);
            emitI32Load(out_);
            emitI32Const(out_, elementSize);
            out_ ~= Op.i32_mul;
            out_ ~= Op.i32_add;

            emitGlobalGet(out_, emitter.spGlobal);
            emitI32Const(out_, valSize);
            out_ ~= Op.i32_sub;
            if (isFloat) {
                out_ ~= Op.f64_load;
                out_ ~= cast(ubyte)0x03;
                leb128u(out_, 0);
            } else {
                emitI32Load(out_);
            }

            emitStoreForSize(out_, elementSize, isFloat);
        }
        
        // Increment length
        emitFPOffset(out_, sliceAddr + sliceLayout.lengthOffset);
        emitFPOffset(out_, sliceAddr + sliceLayout.lengthOffset);
        emitI32Load(out_);
        emitI32Const(out_, 1);
        out_ ~= Op.i32_add;
        emitI32Store(out_);
        
        // ~= expression result is the slice itself (return new length for testing)
        emitFPOffset(out_, sliceAddr + sliceLayout.lengthOffset);
        emitI32Load(out_);
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
                emitI32Const(out_, fieldOffset);
                out_ ~= Op.i32_add;
            }
        }

        // Helper: load a 32-bit field from the slice struct at the given sub-offset
        void loadSliceField(uint subOffset) {
            emitFieldAddr();
            if (subOffset > 0) {
                emitI32Const(out_, subOffset);
                out_ ~= Op.i32_add;
            }
            emitI32Load(out_);
        }

        // Helper: store a 32-bit value to a slice struct sub-field
        // Stack before call: [value]
        void storeSliceField(uint subOffset) {
            emitLocalSet(out_, tempLocalA);
            emitFieldAddr();
            if (subOffset > 0) {
                emitI32Const(out_, subOffset);
                out_ ~= Op.i32_add;
            }
            emitLocalGet(out_, tempLocalA);
            emitI32Store(out_);
        }

        // Store value at SP scratch area
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, valSize);
        out_ ~= Op.i32_sub;
        emitExpression(out_, value);
        emitI32Store(out_);

        // Check if length >= capacity
        loadSliceField(sliceLayout.lengthOffset);
        loadSliceField(sliceLayout.capacityOffset);
        out_ ~= Op.i32_ge_u;

        out_ ~= Op.if_;
        out_ ~= cast(ubyte)0x40;

        // newCapacity = max(capacity * 2, 4)
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, capOff);
        out_ ~= Op.i32_sub;

        loadSliceField(sliceLayout.capacityOffset);
        emitI32Const(out_, 2);
        out_ ~= Op.i32_mul;
        emitI32Const(out_, 4);
        loadSliceField(sliceLayout.capacityOffset);
        emitI32Const(out_, 2);
        out_ ~= Op.i32_mul;
        emitI32Const(out_, 4);
        emitUnsignedMaxSelect(out_);
        emitI32Store(out_);

        // Allocate new buffer via arena
        emitArenaPointer(out_);
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, capOff);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitI32Const(out_, elementSize);
        out_ ~= Op.i32_mul;
        uint allocIdx = emitter.getFuncIndex("__arena_alloc");
        emitWasmCall(out_, allocIdx);

        // Store newBuffer at SP-bufOff
        emitLocalSet(out_, tempLocalA);
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, bufOff);
        out_ ~= Op.i32_sub;
        emitLocalGet(out_, tempLocalA);
        emitI32Store(out_);

        // Copy loop: i = 0
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, ctrOff);
        out_ ~= Op.i32_sub;
        emitI32Const(out_, 0);
        emitI32Store(out_);

        out_ ~= Op.block;
        out_ ~= cast(ubyte)0x40;
        out_ ~= Op.loop;
        out_ ~= cast(ubyte)0x40;

        // if i >= length break
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, ctrOff);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        loadSliceField(sliceLayout.lengthOffset);
        out_ ~= Op.i32_ge_u;
        emitBrIf(out_, 1);

        // newBuffer[i] = oldPtr[i] (scalar copy)
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, bufOff);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, ctrOff);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitI32Const(out_, elementSize);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;

        // Load from old ptr[i]
        loadSliceField(0);  // slice.ptr
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, ctrOff);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitI32Const(out_, elementSize);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;
        emitLoadForSize(out_, elementSize, false);
        emitStoreForSize(out_, elementSize, false);

        // i++
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, ctrOff);
        out_ ~= Op.i32_sub;
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, ctrOff);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitI32Const(out_, 1);
        out_ ~= Op.i32_add;
        emitI32Store(out_);

        emitBr(out_, 0);
        out_ ~= Op.end;
        out_ ~= Op.end;

        // Update slice.ptr = newBuffer
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, bufOff);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        storeSliceField(0);  // slice.ptr

        // Update slice.capacity = newCapacity
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, capOff);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        storeSliceField(sliceLayout.capacityOffset);

        out_ ~= Op.end;  // end if (need grow)

        // Store value at ptr[length]: dest = ptr + length * elemSize
        loadSliceField(0);  // ptr
        loadSliceField(sliceLayout.lengthOffset);  // length
        emitI32Const(out_, elementSize);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;
        // Load value from SP scratch
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, valSize);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitStoreForSize(out_, elementSize, false);

        // Increment length
        loadSliceField(sliceLayout.lengthOffset);
        emitI32Const(out_, 1);
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

        auto targetBt = cast(BasicType)expr.targetType;
        if (!targetBt) {
            // Non-basic target type (pointer casts, etc.) — emit as no-op
            emitExpression(out_, expr.expression);
            return;
        }

        // Determine source WASM kind
        bool srcF64 = isF64Expression(expr.expression);
        bool srcF32 = isF32Expression(expr.expression);
        bool srcI64 = isI64Expression(expr.expression);
        // srcI32 is the default (everything else)

        // Determine target kind
        bool tgtF64 = targetBt.kind == BasicType.Kind.Float64;
        bool tgtF32 = targetBt.kind == BasicType.Kind.Float32;
        bool tgtI64 = targetBt.kind == BasicType.Kind.Int64 || targetBt.kind == BasicType.Kind.UInt64;
        // tgtI32 is the default

        emitExpression(out_, expr.expression);

        // Emit conversion opcode based on source→target type pair
        if (srcF64) {
            if (tgtF32)      out_ ~= Op.f32_demote_f64;
            else if (tgtI64) out_ ~= Op.i64_trunc_f64_s;
            else if (tgtF64) {} // no-op
            else             out_ ~= Op.i32_trunc_f64_s;
        } else if (srcF32) {
            if (tgtF64)      out_ ~= Op.f64_promote_f32;
            else if (tgtI64) out_ ~= Op.i64_trunc_f32_s;
            else if (tgtF32) {} // no-op
            else             out_ ~= Op.i32_trunc_f32_s;
        } else if (srcI64) {
            if (tgtF64)      out_ ~= Op.f64_convert_i64_s;
            else if (tgtF32) out_ ~= Op.f32_convert_i64_s;
            else if (tgtI64) {} // no-op
            else             out_ ~= Op.i32_wrap_i64;
        } else {
            // srcI32
            if (tgtF64)      out_ ~= Op.f64_convert_i32_s;
            else if (tgtF32) out_ ~= Op.f32_convert_i32_s;
            else if (tgtI64) out_ ~= Op.i64_extend_i32_s;
            // else: i32→i32, no-op (e.g., int→uint)
        }
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
                    throw new EmitError("Variable is not a class in cast: " ~ identExpr.name, expr.location);
                }
            } else {
                throw new EmitError("Unknown class variable in cast: " ~ identExpr.name, expr.location);
            }
            
            // Emit itable_ptr
            string ifaceName = targetIface.name;
            if (auto itableBase = ifaceName in srcClass.itableBases) {
                emitI32Const(out_, cast(int)*itableBase);
            } else {
                throw new EmitError("Class " ~ srcClass.name ~ " has no itable for interface " ~ ifaceName, expr.location);
            }
        } else {
            throw new EmitError("Class→interface cast requires identifier expression", expr.location);
        }
    }
    
    void emitMember(ref Appender!(ubyte[]) out_, MemberExpression expr) {
        // Auto-deref: ptr.field where ptr is a pointer to struct
        if (expr.isAutoDereference) {
            emitPointerMemberAccess(out_, expr);
            return;
        }

        // Check if this is a Type.sizeof or Type.alignof
        if (auto ident = cast(IdentifierExpression)expr.object) {
            auto symbol = emitter.symbolTable.lookupSymbol(ident.name);
            if (symbol && symbol.kind == SymbolKind.Type) {
                if (expr.memberName == "sizeof") {
                    // Emit the type's size as a constant
                    size_t size = symbol.type.size();
                    emitI32Const(out_, cast(int)size);
                    return;
                } else if (expr.memberName == "alignof") {
                    // Emit the type's alignment as a constant
                    size_t align_ = symbol.type.alignment();
                    emitI32Const(out_, cast(int)align_);
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
                                        emitI32Const(out_, structAddr + 4);
                                        emitI32Load(out_);
                                        return;
                                    } else if (expr.memberName == "ptr") {
                                        emitI32Const(out_, structAddr);
                                        emitI32Load(out_);
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
                            emitI32Const(out_, structAddr + 4);
                            emitI32Load(out_);
                            return;
                        } else if (expr.memberName == "ptr") {
                            // Ptr is at offset 0
                            emitI32Const(out_, structAddr);
                            emitI32Load(out_);
                            return;
                        } else if (expr.memberName == "capacity") {
                            // Capacity is at offset 8
                            emitI32Const(out_, structAddr + 8);
                            emitI32Load(out_);
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
                                    // Load from data section at struct address + field offset
                                    uint address = varDecl.ctfeStructAddress + cast(uint)field.offset;
                                    emitI32Const(out_, address);
                                    auto bt = cast(BasicType)field.type;
                                    bool isFloat = bt && (bt.kind == BasicType.Kind.Float64 || bt.kind == BasicType.Kind.Float32);
                                    emitLoadForSize(out_, cast(uint)field.size, isFloat);
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
                                    emitI32Const(out_, cast(int)field.offset);
                                    out_ ~= Op.i32_add;
                                }
                                return;  // address of slice struct on stack
                            }
                        }
                        emitVarAddress(out_, info);
                        if (field.offset > 0) {
                            emitI32Const(out_, cast(int)field.offset);
                            out_ ~= Op.i32_add;
                        }
                        auto bt = cast(BasicType)field.type;
                        bool isFloat = bt && (bt.kind == BasicType.Kind.Float64 || bt.kind == BasicType.Kind.Float32);
                        emitLoadForSize(out_, cast(uint)field.size, isFloat);
                        return;
                    }
                } else if (info.isSlice) {
                    int fieldOffset;
                    if (expr.memberName == "ptr") fieldOffset = 0;
                    else if (expr.memberName == "length") fieldOffset = cast(int)sliceLayout.lengthOffset;
                    else if (expr.memberName == "capacity") fieldOffset = cast(int)sliceLayout.capacityOffset;
                    else throw new EmitError("Slice has no field '" ~ expr.memberName ~ "'", expr.location);

                    emitVarAddress(out_, info);
                    if (fieldOffset > 0) {
                        emitI32Const(out_, fieldOffset);
                        out_ ~= Op.i32_add;
                    }
                    emitI32Load(out_);
                    return;
                } else if (info.isStaticArray) {
                    if (expr.memberName == "ptr") {
                        emitVarAddress(out_, info);
                    } else if (expr.memberName == "length") {
                        emitI32Const(out_, cast(int)info.elementCount);
                    } else {
                        throw new EmitError("Static array has no field '" ~ expr.memberName ~ "'", expr.location);
                    }
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
                                else throw new EmitError("Slice field has no member '" ~ expr.memberName ~ "'", expr.location);
                                emitLocalGet(out_, thisInfo.wasmLocalIdx);
                                emitI32Const(out_, cast(int)(field.offset + subOffset));
                                out_ ~= Op.i32_add;
                                emitI32Load(out_);
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
                        emitI32Const(out_, cast(int)field.offset);
                        out_ ~= Op.i32_add;
                    }
                    auto bt = cast(BasicType)field.type;
                    bool isFloat = bt && (bt.kind == BasicType.Kind.Float64 || bt.kind == BasicType.Kind.Float32);
                    emitLoadForSize(out_, cast(uint)field.size, isFloat);
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
                            emitI32Const(out_, fieldOffset);
                            out_ ~= Op.i32_add;
                        }
                        emitI32Load(out_);
                        return;
                    }
                }
            }
        }

        // Handle string literal member access: "hello".ptr, "hello".length
        if (auto lit = cast(LiteralExpression)expr.object) {
            if (lit.value.type == typeid(string)) {
                string strValue = lit.value.get!string();
                uint structAddr = emitter.registerArrayLiteral(strValue);

                if (expr.memberName == "ptr") {
                    emitI32Const(out_, structAddr);
                    emitI32Load(out_);
                    return;
                } else if (expr.memberName == "length") {
                    emitI32Const(out_, structAddr + 4);
                    emitI32Load(out_);
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
                        emitI32Const(out_, cast(int)field.offset);
                        out_ ~= Op.i32_add;
                    }
                    auto bt = cast(BasicType)field.type;
                    bool isFloat = bt && (bt.kind == BasicType.Kind.Float64 || bt.kind == BasicType.Kind.Float32);
                    emitLoadForSize(out_, cast(uint)field.size, isFloat);
                    return;
                }
            }
            // Inner member is a slice — handle .length/.ptr/.capacity
            if (auto arrType = cast(ArrayType)innerType) {
                if (!arrType.isStaticArray) {
                    // Address of the slice struct is on the stack
                    if (expr.memberName == "length") {
                        emitI32Const(out_, sliceLayout.lengthOffset);
                        out_ ~= Op.i32_add;
                    } else if (expr.memberName == "ptr") {
                        // ptr is at offset 0, no add needed
                    } else if (expr.memberName == "capacity") {
                        emitI32Const(out_, sliceLayout.capacityOffset);
                        out_ ~= Op.i32_add;
                    } else {
                        throw new EmitError("Slice field has no member '" ~ expr.memberName ~ "'", expr.location);
                    }
                    emitI32Load(out_);
                    return;
                }
            }
        }

        // Generic fallback: emit the object expression, then access the member
        // based on the type-checked type. This handles string literals, call results,
        // and any other expression that produces a typed value.
        if (expr.object.type !is null) {
            auto objType = expr.object.type.resolve();

            // Slice/array: object emits address of {ptr, length, capacity} struct
            if (auto arrType = cast(ArrayType) objType) {
                if (!arrType.isStaticArray) {
                    emitExpression(out_, expr.object);
                    if (expr.memberName == "ptr") {
                        // ptr is at offset 0
                    } else if (expr.memberName == "length") {
                        emitI32Const(out_, sliceLayout.lengthOffset);
                        out_ ~= Op.i32_add;
                    } else if (expr.memberName == "capacity") {
                        emitI32Const(out_, sliceLayout.capacityOffset);
                        out_ ~= Op.i32_add;
                    } else {
                        throw new EmitError("Array/slice has no member '" ~ expr.memberName ~ "'", expr.location);
                    }
                    emitI32Load(out_);
                    return;
                }
            }

            // Struct: object emits address of struct
            if (auto structDecl = objType.asStruct()) {
                auto field = structDecl.getField(expr.memberName);
                if (field) {
                    emitExpression(out_, expr.object);
                    if (field.offset > 0) {
                        emitI32Const(out_, cast(int) field.offset);
                        out_ ~= Op.i32_add;
                    }
                    auto bt = cast(BasicType)field.type;
                    bool isFloat = bt && (bt.kind == BasicType.Kind.Float64 || bt.kind == BasicType.Kind.Float32);
                    emitLoadForSize(out_, cast(uint)field.size, isFloat);
                    return;
                }
            }
        }

        throw new EmitError("Member access not yet fully implemented for "
            ~ typeid(expr.object).name ~ " object", expr.location);
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
                            emitI32Const(out_, cast(int)field.offset);
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
                    emitI32Const(out_, cast(int)field.offset);
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
                    emitI32Const(out_, cast(int)field.offset);
                    out_ ~= Op.i32_add;
                }
                return;
            }
        }
        throw new EmitError("Cannot compute address of member", expr.location);
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
            return bt.kind == BasicType.Kind.Float64;
        return false;
    }

    /// Check if an element type is a 32-bit floating point.
    private static bool isF32ElementType(Type t) {
        if (auto bt = cast(BasicType)t)
            return bt.kind == BasicType.Kind.Float32;
        return false;
    }

    /// Check if an expression produces f64 on the WASM stack.
    private bool isF64Expression(Expression expr) {
        assert(expr.type !is null,
            "isF64Expression: expr.type not set — type checker must set type on all expressions before codegen");
        auto bt = cast(BasicType)expr.type.resolve();
        if (bt)
            return bt.kind == BasicType.Kind.Float64;
        return false;
    }

    /// Check if an expression produces f32 on the WASM stack.
    private bool isF32Expression(Expression expr) {
        assert(expr.type !is null,
            "isF32Expression: expr.type not set — type checker must set type on all expressions before codegen");
        auto bt = cast(BasicType)expr.type.resolve();
        if (bt)
            return bt.kind == BasicType.Kind.Float32;
        return false;
    }

    /// Check if an expression produces an i64 (long/ulong) value on the WASM stack.
    private bool isI64Expression(Expression expr) {
        assert(expr.type !is null,
            "isI64Expression: expr.type not set — type checker must set type on all expressions before codegen");
        auto resolved = expr.type.resolve();
        auto bt = cast(BasicType)resolved;
        if (bt)
            return bt.kind == BasicType.Kind.Int64 || bt.kind == BasicType.Kind.UInt64;
        // ObjC interface/class types are i64 (opaque native pointers)
        if (auto ut = cast(UserType)resolved) {
            if (auto ifaceDecl = cast(InterfaceDecl)ut.declaration) {
                if (ifaceDecl.isObjC) return true;
            }
            if (auto classDecl = cast(ClassDecl)ut.declaration) {
                if (classDecl.isObjC) return true;
            }
        }
        return false;
    }

    /// Emit a load instruction appropriate for the given element size.
    void emitLoadForSize(ref Appender!(ubyte[]) out_, uint elemSize, bool isFloat = false) {
        if (elemSize == 1) {
            out_ ~= Op.i32_load8_u;
            out_ ~= cast(ubyte)0x00;
            leb128u(out_, 0);
        } else if (elemSize == 2) {
            out_ ~= Op.i32_load16_u;
            out_ ~= cast(ubyte)0x01;  // alignment log2(2)
            leb128u(out_, 0);
        } else if (elemSize == 8 && isFloat) {
            out_ ~= Op.f64_load;
            out_ ~= cast(ubyte)0x03;  // alignment log2(8)
            leb128u(out_, 0);
        } else if (elemSize == 8) {
            emitI64Load(out_);
        } else if (elemSize == 4 && isFloat) {
            out_ ~= Op.f32_load;
            out_ ~= cast(ubyte)0x02;  // alignment log2(4)
            leb128u(out_, 0);
        } else {
            emitI32Load(out_);
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
        } else if (elemSize == 4 && isFloat) {
            out_ ~= Op.f32_store;
            out_ ~= cast(ubyte)0x02;  // alignment log2(4)
            leb128u(out_, 0);
        } else {
            emitI32Store(out_);
        }
    }

    void emitLiteral(ref Appender!(ubyte[]) out_, LiteralExpression expr) {
        // If expression type indicates f32, emit f32_const (literal stored as double, demote here)
        if (isF32Expression(expr)) {
            emitF32Const(out_, cast(float)(expr.value.type == typeid(double) ? expr.value.get!double() : 0.0));
            return;
        }

        // If expression type indicates i64, emit i64_const regardless of variant type
        if (isI64Expression(expr)) {
            long value;
            if (expr.value.type == typeid(long))
                value = expr.value.get!long();
            else if (expr.value.type == typeid(int))
                value = expr.value.get!int();
            else
                value = 0;
            emitI64Const(out_, value);
            return;
        }

        if (expr.value.type == typeid(long)) {
            long value = expr.value.get!long();
            // Handle 32-bit values: allow both signed i32 and unsigned u32 range
            // Values like 0xEDB88320 (3988292384) are valid u32 but exceed i32.max
            // Convert to signed i32 via two's complement for WASM encoding
            if (value > uint.max || value < int.min) {
                throw new EmitError(
                    format("Integer literal %d exceeds 32-bit range [%d, %d]", value, int.min, uint.max),
                    expr.location
                );
            }
            // If value is in unsigned range but above signed max, convert to signed
            int i32Value = (value > int.max) ? cast(int)(value & 0xFFFFFFFF) : cast(int)value;
            emitI32Const(out_, i32Value);
        } else if (expr.value.type == typeid(bool)) {
            emitI32Const(out_, expr.value.get!bool() ? 1 : 0);
        } else if (expr.value.type == typeid(char)) {
            emitI32Const(out_, cast(int)expr.value.get!char());
        } else if (expr.value.type == typeid(double)) {
            emitF64Const(out_, expr.value.get!double());
        } else if (expr.value.type == typeid(string)) {
            // String literal: emit pointer to Array struct
            string s = expr.value.get!string();
            uint structAddr = emitter.registerArrayLiteral(s);
            emitI32Const(out_, structAddr);
        } else {
            throw new EmitError("Unsupported literal type", expr.location);
        }
    }
    
    void emitIdentifier(ref Appender!(ubyte[]) out_, IdentifierExpression expr) {
        // Check captures first (lifted lambda env access)
        foreach (ref cap; captures) {
            if (cap.name == expr.name) {
                // By-reference capture: env stores pointer to captured var's shadow stack slot
                emitLocalGet(out_, envParamIdx);
                if (cap.envOffset > 0) {
                    emitI32Const(out_, cap.envOffset);
                    out_ ~= Op.i32_add;
                }
                emitI32Load(out_);
                emitI32Load(out_);
                return;
            }
        }
        // Unified variable resolution: check varsByLocalId/varsByName first
        if (auto info = resolveVar(expr.resolvedLocalId, expr.name)) {
            final switch (info.addrMode) {
                case AddrMode.wasmLocal:
                    emitLocalGet(out_, info.wasmLocalIdx);
                    return;
                case AddrMode.shadowStack:
                    emitFPOffset(out_, info.frameOffset);
                    // Scalar on shadow stack (promoted for capture): load value
                    if (info.kind == VarKind.scalar) {
                        emitI32Load(out_);
                    }
                    return;
                case AddrMode.paramPointer:
                    emitLocalGet(out_, info.wasmLocalIdx);
                    // ref scalar param: deref pointer to get value
                    if (info.kind == VarKind.scalar) {
                        emitI32Load(out_);
                    }
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
                            emitLocalGet(out_, thisInfo.wasmLocalIdx);
                            if (field.offset > 0) {
                                emitI32Const(out_, cast(int)field.offset);
                                out_ ~= Op.i32_add;
                            }
                            return;  // address of slice struct on stack
                        }
                    }
                    emitLocalGet(out_, thisInfo.wasmLocalIdx);
                    if (field.offset > 0) {
                        emitI32Const(out_, cast(int)field.offset);
                        out_ ~= Op.i32_add;
                    }
                    emitI32Load(out_);
                    return;
                }
            }
        }

        // Check if it's a manifest constant (CTFE-evaluated lazily)
        if (symbol && symbol.isConstant) {
            if (auto manifest = cast(ManifestConstantDecl)symbol.declaration) {
                assert(manifest.ownModuleResolver !is null,
                    "Manifest '" ~ manifest.name ~ "' reached codegen without resolver stamp");
                manifest.ensureEvaluated();
                if (manifest.isStringType) {
                    uint structAddr = emitter.registerArrayLiteral(manifest.ctfeStringValue);
                    emitI32Const(out_, structAddr);
                } else if (manifest.isFloatType) {
                    // Check if manifest is explicitly typed as Float32
                    bool isF32Manifest = false;
                    if (auto mbt = cast(BasicType)manifest.inferredType)
                        isF32Manifest = mbt.kind == BasicType.Kind.Float32;
                    if (isF32Manifest) {
                        emitF32Const(out_, cast(float)manifest.ctfeFloatValue);
                    } else {
                        emitF64Const(out_, manifest.ctfeFloatValue);
                    }
                } else {
                    emitI32Const(out_, manifest.ctfeValue);
                }
                return;
            }
        }

        // Check if it's a scalar global variable
        if (symbol) {
            if (auto varDecl = cast(VariableDecl)symbol.declaration) {
                if (varDecl.wasmGlobalIndex != uint.max) {
                    emitGlobalGet(out_, varDecl.wasmGlobalIndex);
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
            emitI32Const(out_, 0);
            out_ ~= Op.i32_ne;
            out_ ~= Op.else_;
            emitI32Const(out_, 0);
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
            emitI32Const(out_, 1);
            out_ ~= Op.else_;
            emitExpression(out_, expr.right);
            emitI32Const(out_, 0);
            out_ ~= Op.i32_ne;
            blockDepth--;
            out_ ~= Op.end;
            return;
        }

        // i64 path: emit operands with inline i32→i64 promotion
        bool isLong = !isF64Expression(expr.left) &&
                      (isI64Expression(expr.left) || isI64Expression(expr.right));
        if (isLong) {
            emitExpression(out_, expr.left);
            if (!isI64Expression(expr.left))
                out_ ~= Op.i64_extend_i32_s;
            emitExpression(out_, expr.right);
            if (!isI64Expression(expr.right))
                out_ ~= Op.i64_extend_i32_s;

            Op op;
            switch (expr.operator) {
                case BinaryExpression.Operator.Add: op = Op.i64_add; break;
                case BinaryExpression.Operator.Subtract: op = Op.i64_sub; break;
                case BinaryExpression.Operator.Multiply: op = Op.i64_mul; break;
                case BinaryExpression.Operator.Divide: op = Op.i64_div_s; break;
                case BinaryExpression.Operator.Modulo: op = Op.i64_rem_s; break;
                case BinaryExpression.Operator.Equal: op = Op.i64_eq; break;
                case BinaryExpression.Operator.NotEqual: op = Op.i64_ne; break;
                case BinaryExpression.Operator.Less: op = Op.i64_lt_s; break;
                case BinaryExpression.Operator.LessEqual: op = Op.i64_le_s; break;
                case BinaryExpression.Operator.Greater: op = Op.i64_gt_s; break;
                case BinaryExpression.Operator.GreaterEqual: op = Op.i64_ge_s; break;
                case BinaryExpression.Operator.BitwiseAnd: op = Op.i64_and; break;
                case BinaryExpression.Operator.BitwiseOr: op = Op.i64_or; break;
                case BinaryExpression.Operator.BitwiseXor: op = Op.i64_xor; break;
                default:
                    assert(0, "i64 binary operator not supported: " ~ to!string(expr.operator));
            }
            out_ ~= op;
            return;
        }

        // Emit operands
        emitExpression(out_, expr.left);
        emitExpression(out_, expr.right);

        // Emit operator — dispatch f64/f32 ops when operands are float
        Op op;
        bool isF64 = isF64Expression(expr.left);
        bool isF32 = isF32Expression(expr.left);
        if (isF64) {
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
        } else if (isF32) {
            switch (expr.operator) {
                case BinaryExpression.Operator.Add: op = Op.f32_add; break;
                case BinaryExpression.Operator.Subtract: op = Op.f32_sub; break;
                case BinaryExpression.Operator.Multiply: op = Op.f32_mul; break;
                case BinaryExpression.Operator.Divide: op = Op.f32_div; break;
                case BinaryExpression.Operator.Equal: op = Op.f32_eq; break;
                case BinaryExpression.Operator.NotEqual: op = Op.f32_ne; break;
                case BinaryExpression.Operator.Less: op = Op.f32_lt; break;
                case BinaryExpression.Operator.LessEqual: op = Op.f32_le; break;
                case BinaryExpression.Operator.Greater: op = Op.f32_gt; break;
                case BinaryExpression.Operator.GreaterEqual: op = Op.f32_ge; break;
                default:
                    assert(0, "Float binary operator not supported: " ~ to!string(expr.operator));
            }
        } else {
            // Safety: if either operand is float, it should have been caught above.
            assert(!isF64Expression(expr.right) && !isF32Expression(expr.right),
                "emitBinary: right operand is float but left was not detected as float — type mismatch in binary expression");
            final switch (expr.operator) {
            case BinaryExpression.Operator.Add: op = Op.i32_add; break;
            case BinaryExpression.Operator.Subtract: op = Op.i32_sub; break;
            case BinaryExpression.Operator.Multiply: op = Op.i32_mul; break;
            case BinaryExpression.Operator.Divide:
                if (enableStackTrace) {
                    emitCheckedDivOrMod(out_, Op.i32_div_s, expr.location);
                    return;
                }
                op = Op.i32_div_s; break;
            case BinaryExpression.Operator.Modulo:
                if (enableStackTrace) {
                    emitCheckedDivOrMod(out_, Op.i32_rem_s, expr.location);
                    return;
                }
                op = Op.i32_rem_s; break;
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
        }
        out_ ~= op;
    }
    
    void emitArrayConcat(ref Appender!(ubyte[]) out_, BinaryExpression expr) {
        // Emit left operand (pushes array struct pointer)
        emitExpression(out_, expr.left);
        
        // Emit right operand (pushes array struct pointer)
        emitExpression(out_, expr.right);
        
        // Call __array_concat(s1, s2) -> result_ptr
        emitWasmCall(out_, emitter.concatFuncIndex);
    }
    
    void emitUnary(ref Appender!(ubyte[]) out_, UnaryExpression expr) {
        if (expr.loweredCall) { emitExpression(out_, expr.loweredCall); return; }
        final switch (expr.operator) {
            case UnaryExpression.Operator.Plus:
                emitExpression(out_, expr.operand);
                break;
                
            case UnaryExpression.Operator.Minus:
                if (isF64Expression(expr)) {
                    emitExpression(out_, expr.operand);
                    out_ ~= Op.f64_neg;
                } else if (isF32Expression(expr)) {
                    emitExpression(out_, expr.operand);
                    out_ ~= Op.f32_neg;
                } else if (isI64Expression(expr)) {
                    emitI64Const(out_, 0);
                    emitExpression(out_, expr.operand);
                    out_ ~= Op.i64_sub;
                } else {
                    emitI32Const(out_, 0);
                    emitExpression(out_, expr.operand);
                    out_ ~= Op.i32_sub;
                }
                break;
                
            case UnaryExpression.Operator.LogicalNot:
                emitExpression(out_, expr.operand);
                out_ ~= Op.i32_eqz;
                break;
                
            case UnaryExpression.Operator.BitwiseNot:
                emitExpression(out_, expr.operand);
                emitI32Const(out_, -1);
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
                emitAddressOf(out_, expr);
                break;

            case UnaryExpression.Operator.Dereference:
                emitDereference(out_, expr);
                break;
        }
    }
    
    void emitAddressOf(ref Appender!(ubyte[]) out_, UnaryExpression expr) {
        // &var — emit the memory address of the operand
        if (auto ident = cast(IdentifierExpression)expr.operand) {
            if (auto info = resolveVar(ident.resolvedLocalId, ident.name)) {
                if (info.addrMode == AddrMode.shadowStack) {
                    // Struct/slice/staticArray on shadow stack: FP + offset IS the address
                    emitVarAddress(out_, info);
                    return;
                } else if (info.addrMode == AddrMode.paramPointer) {
                    // Struct/slice param: the local holds the pointer already
                    emitLocalGet(out_, info.wasmLocalIdx);
                    return;
                }
            }
        }
        throw new EmitError("Cannot take address of this expression", expr.location);
    }

    void emitDereference(ref Appender!(ubyte[]) out_, UnaryExpression expr) {
        // *ptr — dereference a pointer
        // Resolve the pointer's type to determine the pointee
        PointerType ptrType = resolvePointerType(expr.operand);
        emitExpression(out_, expr.operand);
        if (ptrType && !ptrType.pointeeType.isBasicType()) {
            // Struct/aggregate pointer: the pointer value IS the struct address — no load needed
            return;
        }
        // Scalar deref: load value from address using size-appropriate instruction
        if (ptrType) {
            uint elemSize = wasmElementSize(ptrType.pointeeType);
            bool isFloat = false;
            if (auto bt = cast(BasicType)ptrType.pointeeType)
                isFloat = bt.kind == BasicType.Kind.Float64 || bt.kind == BasicType.Kind.Float32;
            emitLoadForSize(out_, elemSize, isFloat);
        } else {
            // Fallback: assume i32
            emitI32Load(out_);
        }
    }

    /// Resolve the PointerType of an expression by checking variable info or expr.type.
    private PointerType resolvePointerType(Expression expr) {
        // Try expr.type first (set by type checker for some expressions)
        if (auto pt = cast(PointerType)expr.type)
            return pt;
        // Try resolving from variable info
        if (auto ident = cast(IdentifierExpression)expr) {
            if (auto info = resolveVar(ident.resolvedLocalId, ident.name)) {
                return cast(PointerType)info.type;
            }
        }
        return null;
    }

    /// Resolve the aggregate (struct or class) pointed to by a pointer expression.
    private AggregateDecl resolvePointeeAggregate(Expression objectExpr) {
        // Try variable info
        if (auto ident = cast(IdentifierExpression)objectExpr) {
            if (auto info = resolveVar(ident.resolvedLocalId, ident.name)) {
                if (auto ptrType = cast(PointerType)info.type) {
                    if (auto userType = cast(UserType)ptrType.pointeeType) {
                        userType.ensureResolved(emitter.symbolTable);
                        if (auto sd = cast(StructDecl)userType.declaration) return sd;
                        if (auto cd = cast(ClassDecl)userType.declaration) return cd;
                    }
                }
            }
        }
        // Try expr.type (from type checker)
        if (auto ptrType = cast(PointerType)objectExpr.type) {
            if (auto userType = cast(UserType)ptrType.pointeeType) {
                userType.ensureResolved(emitter.symbolTable);
                if (auto sd = cast(StructDecl)userType.declaration) return sd;
                if (auto cd = cast(ClassDecl)userType.declaration) return cd;
            }
        }
        return null;
    }

    /// Emit ptr.field — auto-deref pointer to struct/class, access field
    void emitPointerMemberAccess(ref Appender!(ubyte[]) out_, MemberExpression expr) {
        auto aggDecl = resolvePointeeAggregate(expr.object);
        if (!aggDecl)
            throw new EmitError("Cannot resolve type for pointer dereference", expr.location);

        auto field = aggDecl.getField(expr.memberName);
        if (!field)
            throw new EmitError(format("'%s' has no field '%s'", aggDecl.name, expr.memberName), expr.location);

        // Emit pointer value (the struct base address)
        emitExpression(out_, expr.object);
        if (field.offset > 0) {
            emitI32Const(out_, cast(int)field.offset);
            out_ ~= Op.i32_add;
        }
        auto bt = cast(BasicType)field.type;
        bool isFloat = bt && (bt.kind == BasicType.Kind.Float64 || bt.kind == BasicType.Kind.Float32);
        emitLoadForSize(out_, cast(uint)field.size, isFloat);
    }

    /// Emit ptr.field = value — auto-deref pointer to struct/class, assign field
    void emitPointerMemberAssignment(ref Appender!(ubyte[]) out_, MemberExpression member, Expression value) {
        auto aggDecl = resolvePointeeAggregate(member.object);
        if (!aggDecl)
            throw new EmitError("Cannot resolve type for pointer assignment", member.location);

        auto field = aggDecl.getField(member.memberName);
        if (!field)
            throw new EmitError(format("'%s' has no field '%s'", aggDecl.name, member.memberName), member.location);

        // Store: [ptr + offset, value] → store
        emitExpression(out_, member.object);
        if (field.offset > 0) {
            emitI32Const(out_, cast(int)field.offset);
            out_ ~= Op.i32_add;
        }
        emitExpression(out_, value);
        auto bt = cast(BasicType)field.type;
        bool isFloat = bt && (bt.kind == BasicType.Kind.Float64 || bt.kind == BasicType.Kind.Float32);
        emitStoreForSize(out_, cast(uint)field.size, isFloat);

        // Re-emit value for expression result
        emitExpression(out_, value);
    }

    /// Emit field stores at address in tempLocalA. Shared by emplace and new (structs and classes).
    private void emitFieldStores(ref Appender!(ubyte[]) out_, AggregateDecl aggDecl, Expression[] fieldArgs) {
        // Initialize each field at ptr + field.offset
        for (size_t i = 0; i < fieldArgs.length; i++) {
            auto field = aggDecl.fields[i];
            emitLocalGet(out_, tempLocalA);
            if (field.offset > 0) {
                emitI32Const(out_, cast(int)field.offset);
                out_ ~= Op.i32_add;
            }
            emitExpression(out_, fieldArgs[i]);
            auto bt = cast(BasicType)field.type;
            bool isFloat = bt && (bt.kind == BasicType.Kind.Float64 || bt.kind == BasicType.Kind.Float32);
            emitStoreForSize(out_, cast(uint)field.size, isFloat);
        }

        // Zero-init remaining fields
        for (size_t i = fieldArgs.length; i < aggDecl.fields.length; i++) {
            auto field = aggDecl.fields[i];
            auto bt = cast(BasicType)field.type;
            bool isFloat = bt && (bt.kind == BasicType.Kind.Float64 || bt.kind == BasicType.Kind.Float32);
            uint fieldSize = cast(uint)field.size;
            emitLocalGet(out_, tempLocalA);
            if (field.offset > 0) {
                emitI32Const(out_, cast(int)field.offset);
                out_ ~= Op.i32_add;
            }
            if (isFloat) {
                out_ ~= Op.f64_const;
                foreach (_; 0 .. 8) out_ ~= cast(ubyte)0;  // f64 0.0
                out_ ~= Op.f64_store;
                out_ ~= cast(ubyte)0x03;  // align = 8
                leb128u(out_, 0);
            } else if (fieldSize == 8) {
                emitI64Const(out_, 0);
                emitI64Store(out_);
            } else {
                emitI32Const(out_, 0);
                emitI32Store(out_);
            }
        }
    }

    /// Emit emplace(ptr, field1, field2, ...) — inline field stores at pointer address
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
            throw new EmitError("Concat-assign (~=) only supported on slice locals/fields", expr.location);
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

        // Check for pointer dereference assignment (*ptr = value)
        if (auto derefExpr = cast(UnaryExpression)expr.left) {
            if (derefExpr.operator == UnaryExpression.Operator.Dereference) {
                // *ptr = value → [ptr_addr, value, i32.store]
                emitExpression(out_, derefExpr.operand);  // ptr address
                emitExpression(out_, expr.right);          // value
                emitI32Store(out_);
                return;
            }
        }

        auto ident = cast(IdentifierExpression)expr.left;
        if (!ident) {
            throw new EmitError("Complex assignment targets not yet supported", expr.location);
        }

        // Check captures first (lifted lambda env access)
        foreach (ref cap; captures) {
            if (cap.name == ident.name) {
                // Load pointer to captured var from env
                emitLocalGet(out_, envParamIdx);
                if (cap.envOffset > 0) {
                    emitI32Const(out_, cap.envOffset);
                    out_ ~= Op.i32_add;
                }
                emitI32Load(out_);
                // Emit RHS value
                emitExpression(out_, expr.right);
                // Save value, store through pointer, leave value on stack
                emitLocalTee(out_, tempLocalB);
                emitI32Store(out_);
                emitLocalGet(out_, tempLocalB);
                return;
            }
        }

        // Check for implicit field assignment in a method (fieldName = value)
        if (func.structParent !is null || func.classParent !is null) {
            AggregateDecl parent = func.structParent ? cast(AggregateDecl)func.structParent
                                                     : cast(AggregateDecl)func.classParent;
            auto field = parent.getField(ident.name);
            if (field) {
                // Implicit this.fieldName = value
                if (auto thisInfo = resolveVar(THIS_LOCAL_ID, "this")) {
                    emitLocalGet(out_, thisInfo.wasmLocalIdx);
                    if (field.offset > 0) {
                        emitI32Const(out_, cast(int)field.offset);
                        out_ ~= Op.i32_add;
                    }
                    emitExpression(out_, expr.right);
                    emitI32Store(out_);
                    emitExpression(out_, expr.right);
                    return;
                }
            }
        }

        // Unified variable resolution for locals and params
        if (auto info = resolveVar(ident.resolvedLocalId, ident.name)) {
            // ref param assignment: store through pointer
            if (info.addrMode == AddrMode.paramPointer && info.kind == VarKind.scalar) {
                emitLocalGet(out_, info.wasmLocalIdx);  // push ref pointer
                if (expr.operator != AssignmentExpression.Operator.Assign) {
                    // Compound assignment: load current value, compute, store
                    emitLocalGet(out_, info.wasmLocalIdx);
                    emitI32Load(out_);                  // current value
                    emitExpression(out_, expr.right);    // RHS value
                    emitCompoundOp(out_, expr.operator, false, false, expr.location);
                } else {
                    emitExpression(out_, expr.right);    // RHS value
                }
                emitLocalTee(out_, tempLocalB);         // save result for expression value
                emitI32Store(out_);                     // [ptr, val] → store through pointer
                emitLocalGet(out_, tempLocalB);         // leave result on stack
                return;
            }
            if (info.addrMode == AddrMode.wasmLocal) {
                // Scalar local/param — local_set/local_tee
                auto wasmIdx = info.wasmLocalIdx;
                if (expr.loweredCall) {
                    emitExpression(out_, expr.loweredCall);
                } else if (expr.operator != AssignmentExpression.Operator.Assign) {
                    emitLocalGet(out_, wasmIdx);
                    emitExpression(out_, expr.right);
                    // Implicit f64→f32 before compound op on float local
                    if (info.wasmLocalIdx < localTypes.length &&
                        localTypes[info.wasmLocalIdx] == ValType.f32 &&
                        isF64Expression(expr.right))
                        out_ ~= Op.f32_demote_f64;
                    emitCompoundOp(out_, expr.operator, isF64Expression(expr.left), isF32Expression(expr.left), expr.location);
                } else {
                    emitExpression(out_, expr.right);
                    // Implicit f64→f32 for float local assigned double expression
                    if (info.wasmLocalIdx < localTypes.length &&
                        localTypes[info.wasmLocalIdx] == ValType.f32 &&
                        isF64Expression(expr.right))
                        out_ ~= Op.f32_demote_f64;
                }
                emitLocalTee(out_, wasmIdx);
                return;
            }
            // Scalar on shadow stack (promoted for capture): store value
            if (info.addrMode == AddrMode.shadowStack && info.kind == VarKind.scalar) {
                emitVarAddress(out_, info);  // FP + offset
                if (expr.loweredCall) {
                    emitExpression(out_, expr.loweredCall);
                } else if (expr.operator != AssignmentExpression.Operator.Assign) {
                    // Compound assignment: load current, compute, store
                    // Duplicate the address for both load and store
                    emitLocalSet(out_, tempLocalA);
                    emitLocalGet(out_, tempLocalA);
                    emitLocalGet(out_, tempLocalA);
                    emitI32Load(out_);
                    emitExpression(out_, expr.right);
                    emitCompoundOp(out_, expr.operator, isF64Expression(expr.left), isF32Expression(expr.left), expr.location);
                } else {
                    emitExpression(out_, expr.right);
                }
                // Save value, store it, leave value on stack (assignment is an expression)
                emitLocalTee(out_, tempLocalB);
                emitI32Store(out_);
                emitLocalGet(out_, tempLocalB);
                return;
            }
            // Shadow-stack or param-pointer aggregate reassignment: s = expr
            // RHS expression pushes an i32 pointer to the source data.
            // Use memory.copy to bulk-copy to the destination.
            // Future: check for opAssign on structs/classes and dispatch instead.
            if (info.addrMode == AddrMode.shadowStack || info.addrMode == AddrMode.paramPointer) {
                uint size = 0;
                final switch (info.kind) {
                    case VarKind.struct_:
                        size = cast(uint) info.structDecl.structSize;
                        break;
                    case VarKind.class_:
                        size = cast(uint) info.classDecl.classSize;
                        break;
                    case VarKind.slice:
                        size = sliceLayout.totalSize;
                        break;
                    case VarKind.staticArray:
                        size = info.elementCount * info.elementSize;
                        break;
                    case VarKind.interface_:
                        size = 8;
                        break;
                    case VarKind.delegate_:
                        size = 8; // {tableIndex: i32, envPtr: i32}
                        break;
                    case VarKind.scalar:
                        size = 0; // shouldn't reach here; scalars are wasmLocal
                        break;
                }
                if (size > 0) {
                    // [dest, src, len] memory.copy
                    emitVarAddress(out_, info);       // dest
                    emitExpression(out_, expr.right);  // src pointer
                    emitI32Const(out_, size);
                    out_ ~= cast(ubyte) 0xFC;  // memory.copy prefix
                    out_ ~= cast(ubyte) 0x0A;  // memory.copy opcode
                    leb128u(out_, 0);  // dest memory index
                    leb128u(out_, 0);  // src memory index
                    // Assignment expression must leave a value on the stack.
                    // Push dest address (matches scalar path's local_tee semantics).
                    emitVarAddress(out_, info);
                    return;
                }
            }
        }

        // Check for scalar global variable
        Symbol symbol = emitter.symbolTable.lookupSymbol(ident.name);
        if (symbol) {
            if (auto varDecl = cast(VariableDecl)symbol.declaration) {
                if (varDecl.wasmGlobalIndex != uint.max) {
                    if (expr.loweredCall) {
                        emitExpression(out_, expr.loweredCall);
                    } else if (expr.operator != AssignmentExpression.Operator.Assign) {
                        emitGlobalGet(out_, varDecl.wasmGlobalIndex);
                        emitExpression(out_, expr.right);
                        emitCompoundOp(out_, expr.operator, isF64Expression(expr.left), isF32Expression(expr.left), expr.location);
                    } else {
                        emitExpression(out_, expr.right);
                    }
                    emitGlobalSet(out_, varDecl.wasmGlobalIndex);
                    emitGlobalGet(out_, varDecl.wasmGlobalIndex);
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
    private void emitCompoundOp(ref Appender!(ubyte[]) out_, AssignmentExpression.Operator op,
            bool isF64, bool isF32 = false, SourceLocation loc = SourceLocation.init) {
        if (isF64) {
            final switch (op) {
                case AssignmentExpression.Operator.Assign:
                    assert(0, "emitCompoundOp called with Assign");
                case AssignmentExpression.Operator.AddAssign: out_ ~= Op.f64_add; break;
                case AssignmentExpression.Operator.SubtractAssign: out_ ~= Op.f64_sub; break;
                case AssignmentExpression.Operator.MultiplyAssign: out_ ~= Op.f64_mul; break;
                case AssignmentExpression.Operator.DivideAssign: out_ ~= Op.f64_div; break;
                case AssignmentExpression.Operator.ModuloAssign:
                    throw new EmitError("%= not supported for floating-point types", loc);
                case AssignmentExpression.Operator.AndAssign:
                case AssignmentExpression.Operator.OrAssign:
                case AssignmentExpression.Operator.XorAssign:
                    throw new EmitError("bitwise compound assignment not supported for floating-point types", loc);
                case AssignmentExpression.Operator.ShiftLeftAssign:
                    assert(0, "<<= should be lowered to opShiftLeft call");
                case AssignmentExpression.Operator.ShiftRightAssign:
                    assert(0, ">>= should be lowered to opShiftRight call");
                case AssignmentExpression.Operator.ConcatAssign:
                    throw new EmitError("~= should use slice path", SourceLocation.init);
            }
        } else if (isF32) {
            final switch (op) {
                case AssignmentExpression.Operator.Assign:
                    assert(0, "emitCompoundOp called with Assign");
                case AssignmentExpression.Operator.AddAssign: out_ ~= Op.f32_add; break;
                case AssignmentExpression.Operator.SubtractAssign: out_ ~= Op.f32_sub; break;
                case AssignmentExpression.Operator.MultiplyAssign: out_ ~= Op.f32_mul; break;
                case AssignmentExpression.Operator.DivideAssign: out_ ~= Op.f32_div; break;
                case AssignmentExpression.Operator.ModuloAssign:
                    throw new EmitError("%= not supported for floating-point types", loc);
                case AssignmentExpression.Operator.AndAssign:
                case AssignmentExpression.Operator.OrAssign:
                case AssignmentExpression.Operator.XorAssign:
                    throw new EmitError("bitwise compound assignment not supported for floating-point types", loc);
                case AssignmentExpression.Operator.ShiftLeftAssign:
                    assert(0, "<<= should be lowered to opShiftLeft call");
                case AssignmentExpression.Operator.ShiftRightAssign:
                    assert(0, ">>= should be lowered to opShiftRight call");
                case AssignmentExpression.Operator.ConcatAssign:
                    throw new EmitError("~= should use slice path", SourceLocation.init);
            }
        } else {
            final switch (op) {
                case AssignmentExpression.Operator.Assign:
                    assert(0, "emitCompoundOp called with Assign");
                case AssignmentExpression.Operator.AddAssign: out_ ~= Op.i32_add; break;
                case AssignmentExpression.Operator.SubtractAssign: out_ ~= Op.i32_sub; break;
                case AssignmentExpression.Operator.MultiplyAssign: out_ ~= Op.i32_mul; break;
                case AssignmentExpression.Operator.DivideAssign:
                    if (enableStackTrace) {
                        emitCheckedDivOrMod(out_, Op.i32_div_s, loc);
                        break;
                    }
                    out_ ~= Op.i32_div_s; break;
                case AssignmentExpression.Operator.ModuloAssign:
                    if (enableStackTrace) {
                        emitCheckedDivOrMod(out_, Op.i32_rem_s, loc);
                        break;
                    }
                    out_ ~= Op.i32_rem_s; break;
                case AssignmentExpression.Operator.AndAssign: out_ ~= Op.i32_and; break;
                case AssignmentExpression.Operator.OrAssign: out_ ~= Op.i32_or; break;
                case AssignmentExpression.Operator.XorAssign: out_ ~= Op.i32_xor; break;
                case AssignmentExpression.Operator.ShiftLeftAssign:
                    assert(0, "<<= should be lowered to opShiftLeft call");
                case AssignmentExpression.Operator.ShiftRightAssign:
                    assert(0, ">>= should be lowered to opShiftRight call");
                case AssignmentExpression.Operator.ConcatAssign:
                    throw new EmitError("~= should use slice path", SourceLocation.init);
            }
        }
    }
    
    /**
     * Emit assignment to a struct field (p.x = value)
     */
    void emitMemberAssignment(ref Appender!(ubyte[]) out_, MemberExpression member, Expression value) {
        // Auto-deref: ptr.field = value
        if (member.isAutoDereference) {
            emitPointerMemberAssignment(out_, member, value);
            return;
        }

        // Handle index expression objects (points[i].x = value)
        if (auto indexExpr = cast(IndexExpression)member.object) {
            // Emit element address (aggregate mode leaves address on stack)
            emitIntrinsicOpIndex(out_, indexExpr);
            auto elemType = getIndexExpressionElementType(indexExpr);
            if (auto structDecl = elemType.asStruct()) {
                auto field = structDecl.getField(member.memberName);
                if (field) {
                    if (field.offset > 0) {
                        emitI32Const(out_, cast(int)field.offset);
                        out_ ~= Op.i32_add;
                    }
                    emitExpression(out_, value);
                    auto bt = cast(BasicType)field.type;
                    bool isFloat = bt && (bt.kind == BasicType.Kind.Float64 || bt.kind == BasicType.Kind.Float32);
                    // Implicit f64→f32 for float struct fields assigned double expressions
                    if (bt && bt.kind == BasicType.Kind.Float32 && isF64Expression(value))
                        out_ ~= Op.f32_demote_f64;
                    emitStoreForSize(out_, cast(uint)field.size, isFloat);
                    // Re-emit value for expression result
                    emitExpression(out_, value);
                    return;
                }
            }
        }

        auto objIdent = cast(IdentifierExpression)member.object;
        if (!objIdent) {
            throw new EmitError("Complex member assignment targets not yet supported", member.location);
        }
        
        // Unified variable lookup
        if (auto info = resolveVar(objIdent.resolvedLocalId, objIdent.name)) {
            if (info.isStruct || info.isClass) {
                auto aggr = info.isStruct ? cast(AggregateDecl)info.structDecl
                                          : cast(AggregateDecl)info.classDecl;
                auto field = aggr.getField(member.memberName);
                if (!field) {
                    throw new EmitError(format("Unknown field '%s' in '%s'",
                                              member.memberName, aggr.name), member.location);
                }

                // Store: addr + value (type-appropriate for field type)
                auto bt = cast(BasicType)field.type;
                bool isFloat = bt && (bt.kind == BasicType.Kind.Float64 || bt.kind == BasicType.Kind.Float32);

                emitVarAddress(out_, info);
                if (field.offset > 0) {
                    emitI32Const(out_, cast(int)field.offset);
                    out_ ~= Op.i32_add;
                }
                emitExpression(out_, value);
                // Implicit f64→f32 for float struct fields assigned double expressions
                if (bt && bt.kind == BasicType.Kind.Float32 && isF64Expression(value))
                    out_ ~= Op.f32_demote_f64;
                emitStoreForSize(out_, cast(uint)field.size, isFloat);

                // Re-load for expression value
                emitVarAddress(out_, info);
                if (field.offset > 0) {
                    emitI32Const(out_, cast(int)field.offset);
                    out_ ~= Op.i32_add;
                }
                emitLoadForSize(out_, cast(uint)field.size, isFloat);
                return;
            }

            // Slice .length assignment
            if (info.isSlice && member.memberName == "length") {
                emitSliceLengthAssignment(out_, objIdent.name, info, value);
                return;
            }
        }
        
        throw new EmitError("Unsupported member assignment target", member.location);
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
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 4);
        out_ ~= Op.i32_sub;
        emitExpression(out_, newLengthExpr);
        emitI32Store(out_);
        
        // Load current capacity
        emitFPOffset(out_, sliceAddr + sliceLayout.capacityOffset);
        emitI32Load(out_);
        
        // Load newLength for comparison
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 4);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        
        // if (capacity < newLength) - need to reserve
        out_ ~= Op.i32_lt_u;
        
        out_ ~= Op.if_;
        out_ ~= cast(ubyte)0x40;
        
        // Allocate new buffer: __arena_alloc(arena, newLength * 4)
        emitArenaPointer(out_);
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 4);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitI32Const(out_, 4);
        out_ ~= Op.i32_mul;
        uint allocIdx = emitter.getFuncIndex("__arena_alloc");
        emitWasmCall(out_, allocIdx);
        
        // Store newBuffer at SP-8
        // Save return value to temp local first (i32.store needs [addr, val] order)
        emitLocalSet(out_, tempLocalA);
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 8);
        out_ ~= Op.i32_sub;
        emitLocalGet(out_, tempLocalA);
        // Stack: [SP-8, newBuffer]
        emitI32Store(out_);

        // Copy loop: for i = 0 to oldLength-1
        // Init counter at SP-12
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 12);
        out_ ~= Op.i32_sub;
        emitI32Const(out_, 0);
        emitI32Store(out_);
        
        out_ ~= Op.block;
        out_ ~= cast(ubyte)0x40;
        out_ ~= Op.loop;
        out_ ~= cast(ubyte)0x40;
        
        // if (i >= oldLength) break
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 12);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        
        emitFPOffset(out_, sliceAddr + sliceLayout.lengthOffset);
        emitI32Load(out_);
        
        out_ ~= Op.i32_ge_u;
        emitBrIf(out_, 1);
        
        // newBuffer[i] = oldPtr[i]
        // dest addr
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 8);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 12);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitI32Const(out_, 4);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;
        
        // src value
        emitFPOffset(out_, sliceAddr);
        emitI32Load(out_);
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 12);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitI32Const(out_, 4);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;
        emitI32Load(out_);
        
        emitI32Store(out_);
        
        // i++
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 12);
        out_ ~= Op.i32_sub;
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 12);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitI32Const(out_, 1);
        out_ ~= Op.i32_add;
        emitI32Store(out_);
        
        emitBr(out_, 0);
        out_ ~= Op.end;
        out_ ~= Op.end;
        
        // Update ptr = newBuffer
        emitFPOffset(out_, sliceAddr);
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 8);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitI32Store(out_);
        
        // Update capacity = newLength
        emitFPOffset(out_, sliceAddr + sliceLayout.capacityOffset);
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 4);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitI32Store(out_);
        
        out_ ~= Op.end;  // end if (need reserve)
        
        // Zero-init from oldLength to newLength if growing
        emitFPOffset(out_, sliceAddr + sliceLayout.lengthOffset);
        emitI32Load(out_);
        
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 4);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        
        out_ ~= Op.i32_lt_u;  // oldLength < newLength
        
        out_ ~= Op.if_;
        out_ ~= cast(ubyte)0x40;
        
        // Init counter = oldLength
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 12);
        out_ ~= Op.i32_sub;
        emitFPOffset(out_, sliceAddr + sliceLayout.lengthOffset);
        emitI32Load(out_);
        emitI32Store(out_);
        
        out_ ~= Op.block;
        out_ ~= cast(ubyte)0x40;
        out_ ~= Op.loop;
        out_ ~= cast(ubyte)0x40;
        
        // if (i >= newLength) break
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 12);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 4);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        out_ ~= Op.i32_ge_u;
        emitBrIf(out_, 1);
        
        // ptr[i] = 0
        emitFPOffset(out_, sliceAddr);
        emitI32Load(out_);
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 12);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitI32Const(out_, 4);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;
        emitI32Const(out_, 0);
        emitI32Store(out_);
        
        // i++
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 12);
        out_ ~= Op.i32_sub;
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 12);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitI32Const(out_, 1);
        out_ ~= Op.i32_add;
        emitI32Store(out_);
        
        emitBr(out_, 0);
        out_ ~= Op.end;
        out_ ~= Op.end;
        out_ ~= Op.end;  // end if (need zero init)
        
        // Update length = newLength
        emitFPOffset(out_, sliceAddr + sliceLayout.lengthOffset);
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 4);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
        emitI32Store(out_);
        
        // Leave newLength on stack for expression result
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, 4);
        out_ ~= Op.i32_sub;
        emitI32Load(out_);
    }
    
    //==========================================================================
    // Helpers
    //==========================================================================

    /// Returns true if a CallExpression is a struct/class construction (not a real function call).
    bool isConstructionCall(CallExpression call) {
        if (auto ident = cast(IdentifierExpression)call.function_) {
            auto sym = emitter.symbolTable.lookupSymbol(ident.name);
            if (sym && sym.kind == SymbolKind.Type)
                return true;
        }
        return false;
    }

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

                    // ObjC static method call: NSApplication.sharedApplication()
                    if (auto ifaceDecl = objIdent.name in emitter.objcInterfaces) {
                        foreach (m; (*ifaceDecl).methods) {
                            if (m.name == memberExpr.memberName) {
                                return !isVoidType(m.returnType);
                            }
                        }
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
                    
                    // ObjC interface method: check if method returns void
                    if (objInfo && objInfo.isInterface && objInfo.ifaceDecl.isObjC) {
                        foreach (m; objInfo.ifaceDecl.methods) {
                            if (m.name == memberExpr.memberName) {
                                return !isVoidType(m.returnType);
                            }
                        }
                    }

                    // ObjC class method: dispatch via synthetic interface
                    if (objInfo && objInfo.isClass && objInfo.classDecl.isObjC) {
                        if (auto ifaceDecl2 = objInfo.classDecl.name in emitter.objcInterfaces) {
                            foreach (m; (*ifaceDecl2).methods) {
                                if (m.name == memberExpr.memberName)
                                    return !isVoidType(m.returnType);
                            }
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

                // Type-based check for expression receivers (chained calls)
                if (memberExpr.object.type !is null) {
                    auto resolved = memberExpr.object.type.resolve();
                    if (auto ifaceDecl = resolved.asInterface()) {
                        if (ifaceDecl.isObjC) {
                            foreach (m; ifaceDecl.methods) {
                                if (m.name == memberExpr.memberName)
                                    return !isVoidType(m.returnType);
                            }
                        }
                    }
                    // ObjC class expression receiver
                    if (auto classDecl3 = resolved.asClass()) {
                        if (classDecl3.isObjC) {
                            if (auto synthIface = classDecl3.name in emitter.objcInterfaces) {
                                foreach (m; (*synthIface).methods) {
                                    if (m.name == memberExpr.memberName)
                                        return !isVoidType(m.returnType);
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
