/**
 * StatementEmitter — mixin for FuncContext
 * Auto-extracted from func_context.d
 */
module codegen.wasm.emit_statements;

import codegen.wasm.types;
import codegen.emitter : BinaryEmitter, FuncInfo, EmitError;
import codegen.target : WasmFatPointerLayout, WasmVtablePacking, sliceLayout = sliceInfo;
import ast.nodes;
import ast.statements;
import ast.expressions;
import semantic.symbol_table;

import std.array : Appender;
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

mixin template StatementEmitter() {
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
                    case VarKind.class_:
                        if (info.addrMode == AddrMode.wasmLocal)
                            emitVarDecl(out_, varDecl);      // class reference: scalar init
                        else
                            emitClassVarDecl(out_, varDecl);  // stack-allocated class
                        break;
                    case VarKind.interface_:
                        if (info.addrMode == AddrMode.wasmLocal)
                            emitVarDecl(out_, varDecl);           // ObjC interface: scalar i64 init
                        else
                            emitInterfaceVarDecl(out_, varDecl);  // Regular interface: fat pointer init
                        break;
                    case VarKind.staticArray: emitStaticArrayVarDecl(out_, varDecl); break;
                    case VarKind.slice:       emitSliceVarDecl(out_, varDecl); break;
                    case VarKind.scalar:      emitVarDecl(out_, varDecl); break;
                    case VarKind.delegate_:   emitDelegateVarDecl(out_, varDecl); break;
                }
            } else {
                emitVarDecl(out_, varDecl);
            }
        } else if (cast(BreakStatement)stmt) {
            if (loopStack.length == 0)
                throw new EmitError("break statement outside of loop", stmt.location);
            auto ctx = loopStack[$ - 1];
            emitBr(out_, blockDepth - ctx.breakBlockDepth);
        } else if (cast(ContinueStatement)stmt) {
            if (loopStack.length == 0)
                throw new EmitError("continue statement outside of loop", stmt.location);
            auto ctx = loopStack[$ - 1];
            emitBr(out_, blockDepth - ctx.continueBlockDepth);
        } else if (cast(StructDeclarationStatement)stmt) {
            // Inner struct declaration — no runtime code; methods already collected by emitter
        } else if (auto tryStmt = cast(TryStatement)stmt) {
            emitTryStatement(out_, tryStmt);
        } else {
            throw new EmitError("Unsupported statement type", stmt.location);
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
                // Implicit f64→f32 for float-returning functions
                if (auto retBt = cast(BasicType)func.decl.returnType.resolve())
                    if (retBt.kind == BasicType.Kind.Float32 && isF64Expression(stmt.value))
                        out_ ~= Op.f32_demote_f64;
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
     * Write an exception slot at the current depth and set __exception_pending.
     *
     * Emits WASM that:
     * 1. Checks for overflow (depth >= 100 → unreachable)
     * 2. Computes slotAddr = exceptionArrayOffset + depth * 24
     * 3. Writes kind, file_offset, file_len, line, col, value to the slot
     * 4. Increments __exception_depth
     * 5. Sets __exception_pending = 1
     *
     * For UserThrow, `valueLocal` is the WASM local index holding the thrown value.
     * For runtime errors, pass valueLocal = uint.max and value 0 is written.
     */
    void emitExceptionSlotWrite(ref Appender!(ubyte[]) out_,
        uint kind, SourceLocation loc, uint valueLocal = uint.max)
    {
        import codegen.wasm.types : EXCEPTION_SLOT_SIZE, EXCEPTION_MAX_SLOTS,
                                    EXCEPTION_SLOT_KIND, EXCEPTION_SLOT_FILE_OFFSET,
                                    EXCEPTION_SLOT_FILE_LEN, EXCEPTION_SLOT_LINE,
                                    EXCEPTION_SLOT_COL, EXCEPTION_SLOT_VALUE;

        // Overflow check: if depth >= 100, halt
        emitGlobalGet(out_, emitter.exceptionDepthGlobal);
        emitI32Const(out_, EXCEPTION_MAX_SLOTS);
        out_ ~= Op.i32_ge_u;
        out_ ~= Op.if_;
        out_ ~= BlockType.void_;
        blockDepth++;
        out_ ~= Op.unreachable;
        blockDepth--;
        out_ ~= Op.end;

        // Compute slotAddr = exceptionArrayOffset + depth * 24
        emitGlobalGet(out_, emitter.exceptionDepthGlobal);
        emitI32Const(out_, EXCEPTION_SLOT_SIZE);
        out_ ~= Op.i32_mul;
        emitI32Const(out_, emitter.exceptionArrayOffset);
        out_ ~= Op.i32_add;
        emitLocalTee(out_, tempLocalA);

        // Write kind (offset 0)
        emitI32Const(out_, kind);
        emitI32Store(out_, EXCEPTION_SLOT_KIND);

        // Write file_offset (offset 4)
        emitLocalGet(out_, tempLocalA);
        emitI32Const(out_, frameFileOffset);
        emitI32Store(out_, EXCEPTION_SLOT_FILE_OFFSET);

        // Write file_len (offset 8)
        emitLocalGet(out_, tempLocalA);
        emitI32Const(out_, frameFileLen);
        emitI32Store(out_, EXCEPTION_SLOT_FILE_LEN);

        // Write line (offset 12)
        emitLocalGet(out_, tempLocalA);
        emitI32Const(out_, loc.line);
        emitI32Store(out_, EXCEPTION_SLOT_LINE);

        // Write col (offset 16)
        emitLocalGet(out_, tempLocalA);
        emitI32Const(out_, loc.column);
        emitI32Store(out_, EXCEPTION_SLOT_COL);

        // Write value (offset 20)
        emitLocalGet(out_, tempLocalA);
        if (valueLocal != uint.max) {
            emitLocalGet(out_, valueLocal);
        } else {
            emitI32Const(out_, 0);
        }
        emitI32Store(out_, EXCEPTION_SLOT_VALUE);

        // Increment depth
        emitGlobalGet(out_, emitter.exceptionDepthGlobal);
        emitI32Const(out_, 1);
        out_ ~= Op.i32_add;
        emitGlobalSet(out_, emitter.exceptionDepthGlobal);

        // Set __exception_pending = 1
        emitI32Const(out_, 1);
        emitGlobalSet(out_, emitter.exceptionPendingGlobal);
    }

    /**
     * Emit exception check after a function call (void context — no value on stack).
     * If exception pending: propagate by returning (or branch to catch handler).
     */
    void emitExceptionCheck(ref Appender!(ubyte[]) out_, SourceLocation callSite = SourceLocation.init) {
        emitGlobalGet(out_, emitter.exceptionPendingGlobal);
        if (tryStack.length > 0) {
            // Inside try block: branch to catch handler
            emitBrIf(out_, blockDepth - tryStack[$ - 1].catchBlockDepth);
        } else {
            // Not in try block: propagate exception by returning
            out_ ~= Op.if_;
            out_ ~= cast(ubyte)BlockType.void_;
            blockDepth++;
            // Push dummy return value if function returns non-void on WASM stack
            emitDummyReturnValue(out_);
            emitEpilogue(out_);
            out_ ~= Op.return_;
            blockDepth--;
            out_ ~= Op.end;
        }
    }

    /**
     * Emit exception check when a call result value is on the WASM stack.
     * Saves the result to a type-appropriate temp local, checks, restores on normal path.
     */
    void emitExceptionCheckWithValue(ref Appender!(ubyte[]) out_, SourceLocation callSite, bool isI64Value, bool isF64Value = false, bool isF32Value = false) {
        // Save the call result off the stack — use typed temp to match the value on the stack
        assert(!(isI64Value && isF64Value), "emitExceptionCheckWithValue: value cannot be both i64 and f64");
        uint tempLocal = isF64Value ? tempLocalF64 : (isF32Value ? tempLocalF32 : (isI64Value ? tempLocalI64 : tempLocalA));
        emitLocalSet(out_, tempLocal);
        // Check exception flag
        emitGlobalGet(out_, emitter.exceptionPendingGlobal);
        if (tryStack.length > 0) {
            // Inside try block: branch to catch handler (stack is now clean)
            emitBrIf(out_, blockDepth - tryStack[$ - 1].catchBlockDepth);
        } else {
            // Not in try block: propagate
            out_ ~= Op.if_;
            out_ ~= cast(ubyte)BlockType.void_;
            blockDepth++;
            emitDummyReturnValue(out_);
            emitEpilogue(out_);
            out_ ~= Op.return_;
            blockDepth--;
            out_ ~= Op.end;
        }
        // Restore the call result to the stack for normal execution
        emitLocalGet(out_, tempLocal);
    }

    /**
     * Push a dummy zero return value matching the current function's return type.
     * Used during exception propagation where we need to return early with a placeholder.
     */
    private void emitDummyReturnValue(ref Appender!(ubyte[]) out_) {
        if (emitter.isVoidType(func.decl.returnType) || hasLargeReturn)
            return;
        auto retVt = emitter.dTypeToValType(func.decl.returnType);
        if (retVt == ValType.f64) {
            emitF64Const(out_, 0.0);
        } else if (retVt == ValType.f32) {
            emitF32Const(out_, 0.0f);
        } else if (retVt == ValType.i64) {
            emitI64Const(out_, 0);
        } else {
            emitI32Const(out_, 0);
        }
    }

    /**
     * Overwrite the current call stack frame's line/col with the call-site location.
     * Called during exception propagation so the host sees call-site locations
     * instead of function-definition locations in the preserved call chain.
     */
    private void emitCallStackOverwrite(ref Appender!(ubyte[]) out_, SourceLocation callSite) {
        import codegen.wasm.types : CALL_STACK_DEPTH_OFFSET, CALL_STACK_FRAMES_OFFSET,
                                    CALL_STACK_FRAME_SIZE;

        if (!enableStackTrace || callSite.line == 0)
            return;

        // Calculate frameAddr = FRAMES_OFFSET + (depth - 1) * FRAME_SIZE
        emitI32Const(out_, CALL_STACK_FRAMES_OFFSET);
        emitI32Const(out_, CALL_STACK_DEPTH_OFFSET);
        emitI32Load(out_, 0x00);
        emitI32Const(out_, 1);
        out_ ~= Op.i32_sub;
        emitI32Const(out_, CALL_STACK_FRAME_SIZE);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;
        emitLocalTee(out_, tempLocalB);

        // Store call-site line at frameAddr + 16
        emitI32Const(out_, callSite.line);
        emitI32Store(out_, 0x10);

        // Store call-site column at frameAddr + 20
        emitLocalGet(out_, tempLocalB);
        emitI32Const(out_, callSite.column);
        emitI32Store(out_, 0x14);
    }

    /**
     * Emit a throw expression.
     * Writes exception slot with UserThrow kind, then propagates.
     */
    void emitThrowExpression(ref Appender!(ubyte[]) out_, ThrowExpression expr) {
        import codegen.error_kind : ErrorKind;

        // Evaluate the thrown value and save to tempLocalB
        emitExpression(out_, expr.operand);
        emitLocalSet(out_, tempLocalB);

        // Write exception slot (reads thrown value from tempLocalB)
        emitExceptionSlotWrite(out_, ErrorKind.UserThrow, expr.location, tempLocalB);

        if (tryStack.length > 0) {
            // Inside a try block: branch directly to catch handler
            emitBr(out_, blockDepth - tryStack[$ - 1].catchBlockDepth);
        } else {
            // Not in a try block: propagate by returning
            emitDummyReturnValue(out_);
            emitEpilogue(out_);
            out_ ~= Op.return_;
        }
    }

    /**
     * Emit a try/catch statement.
     * Uses nested blocks: outer block for after-try-catch, inner block for catch target.
     * Catch reads from the exception slot stack.
     */
    void emitTryStatement(ref Appender!(ubyte[]) out_, TryStatement stmt) {
        import codegen.wasm.types : EXCEPTION_SLOT_SIZE, EXCEPTION_SLOT_VALUE;

        // block $after_try_catch
        out_ ~= Op.block;
        out_ ~= cast(ubyte)BlockType.void_;
        blockDepth++;
        uint afterTryCatchDepth = blockDepth;

        //   block $catch_handler
        out_ ~= Op.block;
        out_ ~= cast(ubyte)BlockType.void_;
        blockDepth++;
        uint catchHandlerDepth = blockDepth;

        // Push try context so exception checks branch to catch handler
        tryStack ~= TryContext(catchHandlerDepth);

        // Emit try body
        emitStatement(out_, stmt.tryBody);

        // Pop try context
        tryStack = tryStack[0 .. $ - 1];

        // Normal exit: skip catch handler
        emitBr(out_, blockDepth - afterTryCatchDepth);

        //   end $catch_handler
        blockDepth--;
        out_ ~= Op.end;

        // Catch handler: decrement depth, conditionally clear pending flag
        // __exception_depth--
        emitGlobalGet(out_, emitter.exceptionDepthGlobal);
        emitI32Const(out_, 1);
        out_ ~= Op.i32_sub;
        emitGlobalSet(out_, emitter.exceptionDepthGlobal);

        // if (depth == 0) __exception_pending = 0
        emitGlobalGet(out_, emitter.exceptionDepthGlobal);
        out_ ~= Op.i32_eqz;
        out_ ~= Op.if_;
        out_ ~= BlockType.void_;
        blockDepth++;
        emitI32Const(out_, 0);
        emitGlobalSet(out_, emitter.exceptionPendingGlobal);
        blockDepth--;
        out_ ~= Op.end;

        // For each catch clause (currently just the first one)
        if (stmt.catches.length > 0) {
            auto c = stmt.catches[0];
            if (c.paramName !is null && c.paramName.length > 0) {
                // Read caught value from slot[depth].value
                // slotAddr = exceptionArrayOffset + depth * 24
                emitGlobalGet(out_, emitter.exceptionDepthGlobal);
                emitI32Const(out_, EXCEPTION_SLOT_SIZE);
                out_ ~= Op.i32_mul;
                emitI32Const(out_, emitter.exceptionArrayOffset);
                out_ ~= Op.i32_add;
                // Load value field (offset 20)
                emitI32Load(out_, EXCEPTION_SLOT_VALUE);

                auto info = resolveVar(0, c.paramName);
                if (info !is null) {
                    emitLocalSet(out_, info.wasmLocalIdx);
                } else {
                    out_ ~= Op.drop;
                }
            }
            emitStatement(out_, c.body_);
        }

        // end $after_try_catch
        blockDepth--;
        out_ ~= Op.end;

        // If try body and all catches return, code after is unreachable
        if (alwaysReturns(stmt.tryBody)) {
            bool allCatchesReturn = true;
            foreach (c; stmt.catches) {
                if (!alwaysReturns(c.body_)) {
                    allCatchesReturn = false;
                    break;
                }
            }
            if (allCatchesReturn)
                out_ ~= Op.unreachable;
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
        emitLocalSet(out_, returnTempLocalIdx);
        
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
            emitLocalGet(out_, dstLocalIdx);
            if (offset > 0) {
                emitI32Const(out_, offset);
                out_ ~= Op.i32_add;
            }
            
            // Src value
            emitFPOffset(out_, srcFrameOffset + offset);
            emitI32Load(out_);
            
            // Store: [dst_addr, value] -> memory
            emitI32Store(out_);
        }
    }
    
    /**
     * Emit memory copy from one local (address) to another.
     */
    void emitMemoryCopyFromLocal(ref Appender!(ubyte[]) out_, uint dstLocalIdx, uint srcLocalIdx, uint size) {
        for (uint offset = 0; offset < size; offset += 4) {
            // Dst address
            emitLocalGet(out_, dstLocalIdx);
            if (offset > 0) {
                emitI32Const(out_, offset);
                out_ ~= Op.i32_add;
            }
            
            // Src value
            emitLocalGet(out_, srcLocalIdx);
            if (offset > 0) {
                emitI32Const(out_, offset);
                out_ ~= Op.i32_add;
            }
            emitI32Load(out_);
            
            // Store
            emitI32Store(out_);
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
        if (auto tryStmt = cast(TryStatement)stmt) {
            if (!alwaysReturns(tryStmt.tryBody))
                return false;
            foreach (c; tryStmt.catches) {
                if (!alwaysReturns(c.body_))
                    return false;
            }
            return true;
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
        emitBrIf(out_, 1);

        // Body
        emitStatement(out_, stmt.body_);

        // Continue: branch back to loop
        emitBr(out_, 0);

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
            emitBrIf(out_, 1);
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
        emitBr(out_, 0);

        blockDepth--;
        out_ ~= Op.end;  // End loop

        blockDepth--;
        out_ ~= Op.end;  // End block
    }
    
    void emitVarDecl(ref Appender!(ubyte[]) out_, VariableDeclarationStatement stmt) {
        auto info = resolveVar(stmt.uniqueLocalId, stmt.name);
        if (!info) {
            throw new EmitError("emitVarDecl: unresolved local: " ~ stmt.name, stmt.location);
        }

        if (info.addrMode == AddrMode.shadowStack && info.kind == VarKind.scalar) {
            // Captured scalar promoted to shadow stack — store via FP + offset
            emitFPOffset(out_, info.frameOffset);

            if (stmt.initializer) {
                emitExpression(out_, stmt.initializer);
            } else {
                emitI32Const(out_, 0);
            }

            emitI32Store(out_);
            return;
        }

        if (info.addrMode != AddrMode.wasmLocal) {
            throw new EmitError("emitVarDecl: expected scalar local: " ~ stmt.name, stmt.location);
        }

        if (stmt.initializer) {
            emitExpression(out_, stmt.initializer);
            // Implicit f64→f32 for float locals initialized with double expressions
            if (info.wasmLocalIdx < localTypes.length &&
                localTypes[info.wasmLocalIdx] == ValType.f32 &&
                isF64Expression(stmt.initializer))
                out_ ~= Op.f32_demote_f64;
            // Implicit i32→i64 for long locals initialized with int expressions
            if (info.wasmLocalIdx < localTypes.length &&
                localTypes[info.wasmLocalIdx] == ValType.i64 &&
                !isI64Expression(stmt.initializer) &&
                !isF64Expression(stmt.initializer) &&
                !isF32Expression(stmt.initializer))
                out_ ~= Op.i64_extend_i32_s;
        } else {
            // Default-initialize based on local type
            if (info.wasmLocalIdx < localTypes.length &&
                localTypes[info.wasmLocalIdx] == ValType.f64) {
                emitF64Const(out_, 0.0);
            } else if (info.wasmLocalIdx < localTypes.length &&
                       localTypes[info.wasmLocalIdx] == ValType.f32) {
                emitF32Const(out_, 0.0f);
            } else if (info.wasmLocalIdx < localTypes.length &&
                localTypes[info.wasmLocalIdx] == ValType.i64) {
                emitI64Const(out_, 0);
            } else {
                emitI32Const(out_, 0);
            }
        }

        emitLocalSet(out_, info.wasmLocalIdx);
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
                    emitFPOffset(out_, info.frameOffset + cast(int)field.offset + cast(int)off);

                    // Value: 0
                    emitI32Const(out_, 0);

                    // Store
                    emitI32Store(out_);
                }
            }
            return;
        }
        
        // Unwrap lowered operator overload calls (e.g. a + b → a.opBinary!"+"(b))
        Expression effectiveInit = stmt.initializer;
        if (auto binary = cast(BinaryExpression)effectiveInit) {
            if (binary.loweredCall) effectiveInit = binary.loweredCall;
        }
        if (auto unary = cast(UnaryExpression)effectiveInit) {
            if (unary.loweredCall) effectiveInit = unary.loweredCall;
        }

        // Struct construction or function call returning struct
        if (auto callExpr = cast(CallExpression)effectiveInit) {
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
                emitStructReturnCall(out_, ident.name, callExpr.arguments, info.frameOffset, callExpr.location);
                return;
            }
            // Method call returning struct: Point p = s.origin()
            if (auto memberExpr = cast(MemberExpression)callExpr.function_) {
                // Check if this is an ObjC method call
                InterfaceDecl objcIface = null;
                bool objcStaticCall = false;
                if (auto objIdent = cast(IdentifierExpression)memberExpr.object) {
                    auto objVarInfo = resolveVar(objIdent.resolvedLocalId, objIdent.name);
                    if (objVarInfo && objVarInfo.isInterface && objVarInfo.ifaceDecl.isObjC)
                        objcIface = objVarInfo.ifaceDecl;
                    if (!objcIface) {
                        if (auto iface = objIdent.name in emitter.objcInterfaces) {
                            objcIface = *iface;
                            objcStaticCall = true;
                        }
                    }
                }
                if (!objcIface && memberExpr.object.type !is null) {
                    auto resolved = memberExpr.object.type.resolve();
                    if (auto iface = resolved.asInterface()) {
                        if (iface.isObjC) objcIface = iface;
                    }
                }
                if (objcIface !is null) {
                    // ObjC struct return: pass FP + frameOffset directly as result_ptr
                    // so the FFI trampoline writes the struct straight to the local's frame slot.
                    FunctionDecl method = null;
                    foreach (m; objcIface.methods) {
                        if (m.name == memberExpr.memberName) { method = m; break; }
                    }
                    if (method is null)
                        throw new EmitError("No ObjC method '" ~ memberExpr.memberName ~ "' on " ~ objcIface.name, memberExpr.location);

                    string selector = method.objcSelector;
                    if (selector is null) selector = method.name;

                    // Arg 1: receiver (i64)
                    if (objcStaticCall) {
                        uint classNameAddr = emitter.registerCString(objcIface.name);
                        emitI32Const(out_, classNameAddr);
                        uint getClassIdx = emitter.getFuncIndex("objc_getClass", method.location);
                        emitWasmCall(out_, getClassIdx);
                    } else {
                        emitExpression(out_, memberExpr.object);
                    }

                    // Arg 2: selector (i64)
                    uint selAddr = emitter.registerCString(selector);
                    emitI32Const(out_, selAddr);
                    uint selRegIdx = emitter.getFuncIndex("sel_registerName", method.location);
                    emitWasmCall(out_, selRegIdx);

                    // Arg 3: result_ptr = FP + frameOffset (write directly to local)
                    emitLocalGet(out_, fpLocal);
                    if (info.frameOffset > 0) {
                        emitI32Const(out_, info.frameOffset);
                        out_ ~= Op.i32_add;
                    }

                    // User args
                    foreach (i, arg; callExpr.arguments) {
                        if (i < method.parameters.length) {
                            auto paramType = method.parameters[i].type.resolve();
                            if (auto sd = paramType.asStruct()) {
                                emitExpression(out_, arg);
                                emitLocalSet(out_, tempLocalB);
                                foreach (field; sd.fields) {
                                    emitLocalGet(out_, tempLocalB);
                                    if (field.offset > 0) {
                                        emitI32Const(out_, cast(int)field.offset);
                                        out_ ~= Op.i32_add;
                                    }
                                    auto bt = cast(BasicType)field.type;
                                    bool isFloat = bt && (bt.kind == BasicType.Kind.Float64 || bt.kind == BasicType.Kind.Float32);
                                    emitLoadForSize(out_, cast(uint)field.size, isFloat);
                                }
                                continue;
                            }
                        }
                        emitExpression(out_, arg);
                        if (i < method.parameters.length) {
                            ValType expected = emitter.dTypeToValType(method.parameters[i].type);
                            if (expected == ValType.i64 && !isI64Expression(arg))
                                out_ ~= Op.i64_extend_i32_s;
                            if (expected == ValType.f64 && !isF64Expression(arg))
                                out_ ~= Op.f64_convert_i32_s;
                        }
                    }

                    // Call — trampoline writes result directly to FP + frameOffset
                    string importName = method.mangledName;
                    uint funcIdx = emitter.getFuncIndex(importName, method.location);
                    emitWasmCall(out_, funcIdx);
                    return;
                }
                emitStructReturnMethodCall(out_, memberExpr, callExpr.arguments, info.frameOffset);
                return;
            }
            // Fallback: assume struct construction (e.g. complex expression as target)
            emitStructFieldsInit(out_, structDecl, callExpr.arguments,
                                EmitAddrMode.fromFP, info.frameOffset);
            return;
        }
        
        // Struct template construction: Pair!(int, int)(10, 20)
        if (auto tmplInst = cast(TemplateInstantiationExpression)effectiveInit) {
            if (tmplInst.resolvedStructInstantiation) {
                emitStructFieldsInit(out_, structDecl, tmplInst.callArguments,
                                    EmitAddrMode.fromFP, info.frameOffset);
                return;
            }
        }

        // Struct copy: Point b = a (copy from another struct variable)
        if (auto identExpr = cast(IdentifierExpression)effectiveInit) {
            // Check if source is a local struct
            if (auto srcInfo = resolveVar(identExpr.resolvedLocalId, identExpr.name)) if (srcInfo.isStruct) {
                // Copy field by field from source to destination
                for (size_t i = 0; i < structDecl.fields.length; i++) {
                    auto field = structDecl.fields[i];
                    auto bt = cast(BasicType)field.type;
                    bool isFloat = bt && (bt.kind == BasicType.Kind.Float64 || bt.kind == BasicType.Kind.Float32);

                    // Destination address: FP + destOffset + fieldOffset
                    emitFPOffset(out_, info.frameOffset + cast(int)field.offset);

                    // Source value: load from FP + srcOffset + fieldOffset
                    emitFPOffset(out_, srcInfo.frameOffset + cast(int)field.offset);
                    emitLoadForSize(out_, cast(uint)field.size, isFloat);

                    // Store to destination
                    emitStoreForSize(out_, cast(uint)field.size, isFloat);
                }
                return;
            }
            
            // TODO: copy from global struct
        }
        
        throw new EmitError("Unsupported struct initializer: " ~ effectiveInit.toString(), stmt.location);
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
        
        emitFPOffset(out_, info.frameOffset);
        emitI32Const(out_, cast(int)packedVtablePtr);
        emitI32Store(out_);
        
        if (!stmt.initializer) {
            // Zero-initialize all fields (handle multi-word fields like doubles)
            foreach (field; classDecl.fields) {
                uint fieldBytes = cast(uint)field.size;
                for (uint off = 0; off < fieldBytes; off += 4) {
                    emitFPOffset(out_, info.frameOffset + cast(int)field.offset + cast(int)off);
                    emitI32Const(out_, 0);
                    emitI32Store(out_);
                }
            }
            return;
        }
        
        // Constructor call: Dog(42)
        if (auto callExpr = cast(CallExpression)stmt.initializer) {
            // Initialize fields from constructor arguments (same as struct)
            for (size_t i = 0; i < classDecl.fields.length && i < callExpr.arguments.length; i++) {
                auto field = classDecl.fields[i];
                emitFPOffset(out_, info.frameOffset + cast(int)field.offset);
                emitExpression(out_, callExpr.arguments[i]);
                auto bt = cast(BasicType)field.type;
                bool isFloat = bt && (bt.kind == BasicType.Kind.Float64 || bt.kind == BasicType.Kind.Float32);
                emitStoreForSize(out_, cast(uint)field.size, isFloat);
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
                    emitFPOffset(out_, info.frameOffset + offset);
                    // Src value
                    emitFPOffset(out_, srcInfo.frameOffset + offset);
                    emitI32Load(out_);
                    // Store
                    emitI32Store(out_);
                }
                return;
            }
        }
        
        throw new EmitError("Unsupported class initializer", stmt.location);
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
            emitFPOffset(out_, info.frameOffset);
            emitI32Const(out_, 0);
            emitI32Store(out_);
            
            // itable_ptr at offset 4
            emitFPOffset(out_, info.frameOffset + sliceLayout.lengthOffset);
            emitI32Const(out_, 0);
            emitI32Store(out_);
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
                    emitFPOffset(out_, info.frameOffset);

                    emitVarAddress(out_, srcVar);  // src obj addr

                    emitI32Store(out_);
                }
            } else {
                throw new EmitError("Unknown class for interface assignment: " ~ identExpr.name, identExpr.location);
            }
            
            // Now store itable_ptr at offset 4
            if (srcClass) {
                // Look up itable base for this interface
                string ifaceName = info.ifaceDecl.name;
                if (auto itableBase = ifaceName in srcClass.itableBases) {
                    emitFPOffset(out_, info.frameOffset + sliceLayout.lengthOffset);
                    
                    emitI32Const(out_, cast(int)*itableBase);
                    
                    emitI32Store(out_);
                } else {
                    throw new EmitError("Class " ~ srcClass.name ~ " has no itable for interface " ~ ifaceName, stmt.location);
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
                    emitFPOffset(out_, info.frameOffset);
                    
                    if (auto srcInfo = resolveVar(identExpr.resolvedLocalId, identExpr.name)) {
                        if (srcInfo.isClass) {
                            emitVarAddress(out_, srcInfo);
                        }
                    } else {
                        throw new EmitError("Unknown class in cast: " ~ identExpr.name, identExpr.location);
                    }
                    
                    emitI32Store(out_);
                    
                    // Store itable_ptr at offset 4
                    emitFPOffset(out_, info.frameOffset + sliceLayout.lengthOffset);
                    
                    string ifaceName = castExpr.targetInterfaceDecl.name;
                    if (auto itableBase = ifaceName in srcClass.itableBases) {
                        emitI32Const(out_, cast(int)*itableBase);
                    } else {
                        throw new EmitError("Class " ~ srcClass.name ~ " has no itable for " ~ ifaceName, castExpr.location);
                    }

                    emitI32Store(out_);

                    return;
                }
            }
        }
        
        throw new EmitError("Unsupported interface initializer", stmt.location);
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
                emitFPOffset(out_, info.frameOffset + offset);
                emitI32Const(out_, 0);
                emitI32Store(out_);
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
                emitFPOffset(out_, info.dataOffset + cast(int)(i * elemSize));
                
                // Value: the element expression
                emitExpression(out_, arrayLit.elements[i]);

                // Store
                emitStoreForSize(out_, cast(uint)elemSize);
            }
            
            // Now initialize the slice struct:
            // ptr = FP + dataOffset
            emitFPOffset(out_, info.frameOffset);
            
            emitFPOffset(out_, info.dataOffset);
            
            emitI32Store(out_);
            
            // length = elemCount
            emitFPOffset(out_, info.frameOffset + sliceLayout.lengthOffset);
            
            emitI32Const(out_, elemCount);
            
            emitI32Store(out_);
            
            // capacity = elemCount
            emitFPOffset(out_, info.frameOffset + sliceLayout.capacityOffset);
            
            emitI32Const(out_, elemCount);
            
            emitI32Store(out_);
            
            return;
        }
        
        // String literal initializer: "hello" -> ubyte[]
        if (auto literal = cast(LiteralExpression)stmt.initializer) {
            if (literal.value.type == typeid(string)) {
                string strVal = literal.value.get!string();
                uint structAddr = emitter.registerArrayLiteral(strVal);
                uint len = cast(uint)strVal.length;
                
                // Load ptr from data section struct
                emitFPOffset(out_, info.frameOffset);
                
                emitI32Const(out_, structAddr);
                emitI32Load(out_);

                emitI32Store(out_);
                
                // length
                emitFPOffset(out_, info.frameOffset + sliceLayout.lengthOffset);
                
                emitI32Const(out_, len);
                
                emitI32Store(out_);
                
                // capacity = length (immutable string data)
                emitFPOffset(out_, info.frameOffset + sliceLayout.capacityOffset);
                
                emitI32Const(out_, len);
                
                emitI32Store(out_);
                
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
                throw new EmitError("import(): file not found: " ~ filename, importExpr.location);
            }
            
            ubyte[] fileData = cast(ubyte[])read(fullPath);
            uint len = cast(uint)fileData.length;
            
            // Add file data to data section
            uint dataOffset = emitter.addData(fileData);
            
            // Initialize slice struct: ptr = dataOffset, length = len, capacity = len
            emitFPOffset(out_, info.frameOffset);
            emitI32Const(out_, dataOffset);
            emitI32Store(out_);
            
            emitFPOffset(out_, info.frameOffset + sliceLayout.lengthOffset);
            emitI32Const(out_, len);
            emitI32Store(out_);
            
            emitFPOffset(out_, info.frameOffset + sliceLayout.capacityOffset);
            emitI32Const(out_, len);
            emitI32Store(out_);
            
            return;
        }
        
        // Slice expression initializer: arr[1..3]
        if (auto sliceExpr = cast(SliceExpression)stmt.initializer) {
            auto sourceIdent = cast(IdentifierExpression)sliceExpr.array;
            if (!sourceIdent) {
                throw new EmitError("Complex slice source not supported", sliceExpr.location);
            }

            auto sourceInfo = resolveVar(sourceIdent.resolvedLocalId, sourceIdent.name);
            if (!sourceInfo || (!sourceInfo.isSlice && !sourceInfo.isStaticArray)) {
                throw new EmitError("Can only slice local arrays for now", sliceExpr.location);
            }

            // Calculate ptr = base + start * elemSize
            // Store at FP + frameOffset (slice.ptr)
            emitFPOffset(out_, info.frameOffset);

            // Load base address
            if (sourceInfo.isSlice) {
                // Slice source: load .ptr field
                emitVarAddress(out_, sourceInfo);
                emitI32Load(out_);
            } else {
                // Static array source: address IS the data
                emitVarAddress(out_, sourceInfo);
            }
            
            // Add start * elemSize
            emitExpression(out_, sliceExpr.start);
            emitI32Const(out_, sourceInfo.elementSize);
            out_ ~= Op.i32_mul;
            out_ ~= Op.i32_add;
            
            emitI32Store(out_);
            
            // Calculate length = end - start
            // Store at FP + frameOffset + 4 (slice.length at LENGTH_OFFSET)
            emitFPOffset(out_, info.frameOffset + sliceLayout.lengthOffset);
            
            emitExpression(out_, sliceExpr.end);
            emitExpression(out_, sliceExpr.start);
            out_ ~= Op.i32_sub;
            
            emitI32Store(out_);
            
            // Set capacity = length (can't safely grow a view)
            emitFPOffset(out_, info.frameOffset + sliceLayout.capacityOffset);
            
            emitExpression(out_, sliceExpr.end);
            emitExpression(out_, sliceExpr.start);
            out_ ~= Op.i32_sub;
            
            emitI32Store(out_);
            
            return;
        }
        
        // Function call returning a slice — same hidden result pointer pattern as structs
        if (auto callExpr = cast(CallExpression)stmt.initializer) {
            if (auto ident = cast(IdentifierExpression)callExpr.function_) {
                emitStructReturnCall(out_, ident.name, callExpr.arguments, info.frameOffset, callExpr.location);
                return;
            }
        }

        // Manifest array constant initializer: int[] x = MANIFEST_ARR;
        if (auto ident = cast(IdentifierExpression)stmt.initializer) {
            auto symbol = emitter.symbolTable.lookupSymbol(ident.name);
            if (symbol && symbol.isConstant) {
                if (auto manifest = cast(ManifestConstantDecl)symbol.declaration) {
                    if (manifest.isArrayType || manifest.isNestedArrayType) {
                        manifest.ensureEvaluated();
                        uint structAddr = manifest.isNestedArrayType
                            ? emitter.registerManifestNestedArray(manifest)
                            : emitter.registerManifestArray(manifest);
                        // Copy 12-byte {ptr, len, cap} struct to frame
                        // ptr field
                        emitFPOffset(out_, info.frameOffset);
                        emitI32Const(out_, structAddr);
                        emitI32Load(out_);
                        emitI32Store(out_);
                        // len field
                        emitFPOffset(out_, info.frameOffset + sliceLayout.lengthOffset);
                        emitI32Const(out_, structAddr + sliceLayout.lengthOffset);
                        emitI32Load(out_);
                        emitI32Store(out_);
                        // cap field
                        emitFPOffset(out_, info.frameOffset + sliceLayout.capacityOffset);
                        emitI32Const(out_, structAddr + sliceLayout.capacityOffset);
                        emitI32Load(out_);
                        emitI32Store(out_);
                        return;
                    }
                }
            }
        }

        // General expression initializer (e.g. concat result): copy from pointer
        emitVarAddress(out_, infoPtr);           // dest = FP + frameOffset
        emitExpression(out_, stmt.initializer);  // src pointer
        emitI32Const(out_, sliceLayout.totalSize);
        out_ ~= cast(ubyte) 0xFC;  // memory.copy prefix
        out_ ~= cast(ubyte) 0x0A;  // memory.copy opcode
        leb128u(out_, 0);  // dest memory index
        leb128u(out_, 0);  // src memory index
    }

    /**
     * Emit a slice expression to a 12-byte temp on the SP-based stack.
     * Pushes the temp's i32 address onto the WASM value stack.
     * Handles both slice and static array sources.
     */
    void emitSliceExpressionToTemp(ref Appender!(ubyte[]) out_, SliceExpression sliceExpr) {
        auto sourceIdent = cast(IdentifierExpression)sliceExpr.array;
        if (!sourceIdent)
            throw new EmitError("Complex slice source not supported", sliceExpr.location);
        auto srcInfo = resolveVar(sourceIdent.resolvedLocalId, sourceIdent.name);
        if (!srcInfo || (!srcInfo.isSlice && !srcInfo.isStaticArray))
            throw new EmitError("Can only slice array-like variables", sliceExpr.location);
        uint elemSize = srcInfo.elementSize;
        const sliceSize = sliceLayout.totalSize;  // 12

        // Allocate temp: SP -= 12
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, sliceSize);
        out_ ~= Op.i32_sub;
        emitGlobalSet(out_, emitter.spGlobal);

        // Store ptr = base + start * elemSize at SP+0
        emitGlobalGet(out_, emitter.spGlobal);
        if (srcInfo.isSlice) {
            emitVarAddress(out_, srcInfo);
            emitI32Load(out_);
        } else {
            // static array: address IS the data
            emitVarAddress(out_, srcInfo);
        }
        emitExpression(out_, sliceExpr.start);
        emitI32Const(out_, elemSize);
        out_ ~= Op.i32_mul;
        out_ ~= Op.i32_add;
        emitI32Store(out_);

        // Store length = end - start at SP+LENGTH_OFFSET
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, sliceLayout.lengthOffset);
        out_ ~= Op.i32_add;
        emitExpression(out_, sliceExpr.end);
        emitExpression(out_, sliceExpr.start);
        out_ ~= Op.i32_sub;
        emitI32Store(out_);

        // Store capacity = length at SP+CAPACITY_OFFSET
        emitGlobalGet(out_, emitter.spGlobal);
        emitI32Const(out_, sliceLayout.capacityOffset);
        out_ ~= Op.i32_add;
        emitExpression(out_, sliceExpr.end);
        emitExpression(out_, sliceExpr.start);
        out_ ~= Op.i32_sub;
        emitI32Store(out_);

        // Push temp address
        emitGlobalGet(out_, emitter.spGlobal);
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
                emitFPOffset(out_, info.frameOffset + offset);
                emitI32Const(out_, 0);
                emitI32Store(out_);
            }
            return;
        }
        
        // Array literal initializer: [1, 2, 3, 4]
        if (auto arrayLit = cast(ArrayLiteralExpression)stmt.initializer) {
            uint elemCount = cast(uint)arrayLit.elements.length;
            
            // Store each element at FP + frameOffset + i * elemSize
            for (uint i = 0; i < elemCount && i < info.elementCount; i++) {
                // Address: FP + frameOffset + i * elemSize
                emitFPOffset(out_, info.frameOffset + i * info.elementSize);
                
                // Value
                emitExpression(out_, arrayLit.elements[i]);
                
                // Store
                emitI32Store(out_);
            }
            return;
        }
        
        // Function call returning static array: int[3] arr = makeArray(...)
        if (auto callExpr = cast(CallExpression)stmt.initializer) {
            if (auto ident = cast(IdentifierExpression)callExpr.function_) {
                emitStructReturnCall(out_, ident.name, callExpr.arguments, info.frameOffset, callExpr.location);
                return;
            }
        }

        throw new EmitError("Unsupported static array initializer", stmt.location);
    }
    
    //==========================================================================
    // Expression Emission
    //==========================================================================
    

}
