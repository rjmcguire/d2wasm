/**
 * Escape Analysis
 *
 * Analyzes pointer lifetimes to enable two optimizations:
 * 1. Stack promotion: `new T(...)` allocations whose pointers don't escape
 *    the function are allocated on the shadow stack instead of via __alloc.
 * 2. Safety warnings: `&localVar` expressions that escape their scope
 *    (returned or stored in struct fields) are flagged.
 *
 * Conservative: if uncertain, assumes the pointer escapes.
 * Local-only (v1): no inter-procedural analysis.
 *
 * Runs after type checking, before code generation.
 * Enabled via --escape-analysis CLI flag.
 */
module semantic.escape_analyzer;

import ast.nodes;
import ast.statements;
import ast.expressions;
import semantic.symbol_table;

import diagnostic.log : log;

/**
 * Analyze all declarations for pointer escape behavior.
 * Marks NewExpression.stackPromoted = true for non-escaping allocations.
 * Emits warnings for escaping &local pointers.
 */
void analyzeEscapes(Declaration[] declarations, SymbolTable symbolTable) {
    foreach (decl; declarations) {
        if (auto func = cast(FunctionDecl)decl) {
            analyzeFunction(func, symbolTable);
        } else if (auto sd = cast(StructDecl)decl) {
            foreach (member; sd.members) {
                if (auto method = cast(FunctionDecl)member) {
                    analyzeFunction(method, symbolTable);
                }
            }
        } else if (auto cd = cast(ClassDecl)decl) {
            foreach (member; cd.members) {
                if (auto method = cast(FunctionDecl)member) {
                    analyzeFunction(method, symbolTable);
                }
            }
        }
    }
}

/// Info about a local variable initialized from a new expression.
private struct NewLocal {
    NewExpression newExpr;
    bool escapes;
}

private void analyzeFunction(FunctionDecl func, SymbolTable symbolTable) {
    if (func.body_ is null || func.isTemplate) return;

    // Phase 1: collect locals initialized from new expressions
    NewLocal[uint] newLocals;
    collectNewLocals(func.body_, newLocals);

    bool hasAddrOf = containsAddressOf(func.body_);

    // Fast path: nothing to analyze
    if (newLocals.length == 0 && !hasAddrOf) return;

    // Phase 2: scan for escapes of new-result locals
    foreach (id, ref info; newLocals) {
        if (localEscapes(func.body_, id)) {
            info.escapes = true;
        }
    }

    // Mark surviving allocations as stack-promotable
    foreach (id, ref info; newLocals) {
        if (!info.escapes) {
            info.newExpr.stackPromoted = true;
            log(2, "  escape: stack-promoting new in ", func.name);
        } else {
            log(2, "  escape: heap allocation retained in ", func.name);
        }
    }

    // Phase 3: &local safety warnings
    if (hasAddrOf) {
        checkAddressOfEscapes(func.body_, func.name);
    }
}

// ---------------------------------------------------------------------------
// Phase 1: Collect new-result locals
// ---------------------------------------------------------------------------

/// Walk function body and find VariableDeclarationStatements whose
/// initializer is a NewExpression. Record (uniqueLocalId → NewExpression).
private void collectNewLocals(Statement stmt, ref NewLocal[uint] result) {
    if (stmt is null) return;

    if (auto compound = cast(CompoundStatement)stmt) {
        foreach (s; compound.statements)
            collectNewLocals(s, result);
    } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
        if (varDecl.initializer !is null && varDecl.uniqueLocalId != uint.max) {
            if (auto newExpr = cast(NewExpression)varDecl.initializer) {
                // Only struct new for v1 (class stack-promotion is future work)
                if (newExpr.resolvedStruct !is null) {
                    result[varDecl.uniqueLocalId] = NewLocal(newExpr, false);
                }
            }
        }
    } else if (auto ifStmt = cast(IfStatement)stmt) {
        collectNewLocals(ifStmt.thenStatement, result);
        if (ifStmt.elseStatement)
            collectNewLocals(ifStmt.elseStatement, result);
    } else if (auto whileStmt = cast(WhileStatement)stmt) {
        collectNewLocals(whileStmt.body_, result);
    } else if (auto forStmt = cast(ForStatement)stmt) {
        if (forStmt.init) collectNewLocals(forStmt.init, result);
        collectNewLocals(forStmt.body_, result);
    } else if (auto mixinStmt = cast(MixinStatement)stmt) {
        if (mixinStmt.isExpanded) {
            foreach (s; mixinStmt.expandedStatements)
                collectNewLocals(s, result);
        }
    } else if (auto tryStmt = cast(TryStatement)stmt) {
        collectNewLocals(tryStmt.tryBody, result);
        foreach (c; tryStmt.catches)
            collectNewLocals(c.body_, result);
        if (tryStmt.finallyBody !is null)
            collectNewLocals(tryStmt.finallyBody, result);
    }
    // ExpressionStatement, ReturnStatement, BreakStatement, ContinueStatement,
    // StructDeclarationStatement — no local declarations to collect
}

// ---------------------------------------------------------------------------
// Phase 2: Escape detection for new-result locals
// ---------------------------------------------------------------------------

/// Check if a local variable (by uniqueLocalId) escapes in any statement.
/// Escapes: returned, passed to function, stored in field, assigned to
/// another variable, captured by lambda, address taken.
private bool localEscapes(Statement stmt, uint localId) {
    if (stmt is null) return false;

    if (auto compound = cast(CompoundStatement)stmt) {
        foreach (s; compound.statements)
            if (localEscapes(s, localId)) return true;
    } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
        if (exprEscapesLocal(exprStmt.expression, localId)) return true;
    } else if (auto returnStmt = cast(ReturnStatement)stmt) {
        // Returning the pointer itself → escapes
        // But returning a field value (p.x) or derived computation (p.x + p.y) is safe
        if (returnStmt.value !is null) {
            // Direct return of the local variable → escape
            if (auto retIdent = cast(IdentifierExpression)returnStmt.value) {
                if (retIdent.resolvedLocalId == localId) return true;
            }
            // Check for escape contexts within the return expression
            if (exprEscapesLocal(returnStmt.value, localId)) return true;
        }
    } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
        // Assigning to another variable → alias escape
        if (varDecl.initializer !is null && varDecl.uniqueLocalId != localId) {
            if (containsLocalRef(varDecl.initializer, localId))
                return true;
        }
    } else if (auto ifStmt = cast(IfStatement)stmt) {
        if (ifStmt.condition !is null && exprEscapesLocal(ifStmt.condition, localId))
            return true;
        if (localEscapes(ifStmt.thenStatement, localId)) return true;
        if (ifStmt.elseStatement !is null && localEscapes(ifStmt.elseStatement, localId))
            return true;
    } else if (auto whileStmt = cast(WhileStatement)stmt) {
        if (whileStmt.condition !is null && exprEscapesLocal(whileStmt.condition, localId))
            return true;
        if (localEscapes(whileStmt.body_, localId)) return true;
    } else if (auto forStmt = cast(ForStatement)stmt) {
        if (forStmt.init !is null && localEscapes(forStmt.init, localId)) return true;
        if (forStmt.condition !is null && exprEscapesLocal(forStmt.condition, localId))
            return true;
        if (forStmt.update !is null && exprEscapesLocal(forStmt.update, localId))
            return true;
        if (localEscapes(forStmt.body_, localId)) return true;
    } else if (auto mixinStmt = cast(MixinStatement)stmt) {
        if (mixinStmt.isExpanded) {
            foreach (s; mixinStmt.expandedStatements)
                if (localEscapes(s, localId)) return true;
        }
    } else if (auto tryStmt = cast(TryStatement)stmt) {
        if (localEscapes(tryStmt.tryBody, localId)) return true;
        foreach (c; tryStmt.catches)
            if (localEscapes(c.body_, localId)) return true;
        if (tryStmt.finallyBody !is null && localEscapes(tryStmt.finallyBody, localId))
            return true;
    }
    // BreakStatement, ContinueStatement, StructDeclarationStatement — no escapes

    return false;
}

/// Check if an expression causes a local to escape.
/// This checks for escape *contexts* (call args, assignment RHS to fields, etc.)
/// rather than mere presence of the identifier.
private bool exprEscapesLocal(Expression expr, uint localId) {
    if (expr is null) return false;

    // Function call: any argument containing the local → escape (conservative v1)
    if (auto call = cast(CallExpression)expr) {
        foreach (arg; call.arguments) {
            if (containsLocalRef(arg, localId)) return true;
        }
        // Also check the function expression itself (e.g., higher-order)
        if (exprEscapesLocal(call.function_, localId)) return true;
    }

    // Assignment: RHS contains local, LHS is a member (field store) → escape
    if (auto assign = cast(AssignmentExpression)expr) {
        if (containsLocalRef(assign.right, localId)) {
            // Storing into a field → escape
            if (cast(MemberExpression)assign.left) return true;
            // Storing into another variable (not the same local) → alias escape
            if (auto lhsIdent = cast(IdentifierExpression)assign.left) {
                if (lhsIdent.resolvedLocalId != localId) return true;
            }
            // Storing into indexed location → escape
            if (cast(IndexExpression)assign.left) return true;
        }
        // Check if assignment uses lowered call that escapes
        if (assign.loweredCall !is null && exprEscapesLocal(assign.loweredCall, localId))
            return true;
    }

    // Address-of the local → pointer-to-pointer escape
    if (auto unary = cast(UnaryExpression)expr) {
        if (unary.operator == UnaryExpression.Operator.AddressOf) {
            if (containsLocalRef(unary.operand, localId)) return true;
        }
        if (exprEscapesLocal(unary.operand, localId)) return true;
        if (unary.loweredCall !is null && exprEscapesLocal(unary.loweredCall, localId))
            return true;
    }

    // Binary expression: check lowered calls
    if (auto binary = cast(BinaryExpression)expr) {
        if (exprEscapesLocal(binary.left, localId)) return true;
        if (exprEscapesLocal(binary.right, localId)) return true;
        if (binary.loweredCall !is null && exprEscapesLocal(binary.loweredCall, localId))
            return true;
    }

    // Lambda/delegate: if it captures this local → escape
    if (auto funcLit = cast(FunctionLiteralExpression)expr) {
        if (funcLit.capturedOuterLocalIds !is null) {
            foreach (capturedId; funcLit.capturedOuterLocalIds) {
                if (capturedId == localId) return true;
            }
        }
    }

    // Member expression: accessing value-type fields of the local is OK.
    // Pointer/slice/struct fields could leak the allocation's address.
    if (auto member = cast(MemberExpression)expr) {
        if (auto objIdent = cast(IdentifierExpression)member.object) {
            if (objIdent.resolvedLocalId == localId) {
                // obj.field where obj IS the local
                // Safe only if the field is a value type (int, bool, float, etc.)
                if (member.type !is null && member.type.isBasicType())
                    return false;
                // Unknown or non-basic type → conservative: assume escape
                return true;
            }
        }
        // Otherwise recurse into the object expression
        if (exprEscapesLocal(member.object, localId)) return true;
    }

    // Cast: recurse
    if (auto castExpr = cast(CastExpression)expr) {
        if (exprEscapesLocal(castExpr.expression, localId)) return true;
    }

    // Index: recurse
    if (auto index = cast(IndexExpression)expr) {
        if (exprEscapesLocal(index.array, localId)) return true;
        if (exprEscapesLocal(index.index, localId)) return true;
    }

    // Slice: recurse
    if (auto slice = cast(SliceExpression)expr) {
        if (exprEscapesLocal(slice.array, localId)) return true;
        if (exprEscapesLocal(slice.start, localId)) return true;
        if (exprEscapesLocal(slice.end, localId)) return true;
    }

    // Template instantiation with call args
    if (auto tmpl = cast(TemplateInstantiationExpression)expr) {
        foreach (arg; tmpl.callArguments) {
            if (containsLocalRef(arg, localId)) return true;
        }
    }

    // Throw: recurse into operand
    if (auto throwExpr = cast(ThrowExpression)expr) {
        if (exprEscapesLocal(throwExpr.operand, localId)) return true;
    }

    return false;
}

/// Check if an expression tree contains a reference to a specific local ID.
/// Pure containment check — no escape context analysis.
private bool containsLocalRef(Expression expr, uint localId) {
    if (expr is null) return false;

    if (auto ident = cast(IdentifierExpression)expr) {
        return ident.resolvedLocalId == localId;
    }

    if (auto binary = cast(BinaryExpression)expr) {
        return containsLocalRef(binary.left, localId)
            || containsLocalRef(binary.right, localId)
            || containsLocalRef(binary.loweredCall, localId);
    }

    if (auto unary = cast(UnaryExpression)expr) {
        return containsLocalRef(unary.operand, localId)
            || containsLocalRef(unary.loweredCall, localId);
    }

    if (auto call = cast(CallExpression)expr) {
        if (containsLocalRef(call.function_, localId)) return true;
        foreach (arg; call.arguments)
            if (containsLocalRef(arg, localId)) return true;
        return false;
    }

    if (auto member = cast(MemberExpression)expr) {
        return containsLocalRef(member.object, localId);
    }

    if (auto assign = cast(AssignmentExpression)expr) {
        return containsLocalRef(assign.left, localId)
            || containsLocalRef(assign.right, localId)
            || containsLocalRef(assign.loweredCall, localId);
    }

    if (auto castExpr = cast(CastExpression)expr) {
        return containsLocalRef(castExpr.expression, localId);
    }

    if (auto index = cast(IndexExpression)expr) {
        return containsLocalRef(index.array, localId)
            || containsLocalRef(index.index, localId);
    }

    if (auto slice = cast(SliceExpression)expr) {
        return containsLocalRef(slice.array, localId)
            || containsLocalRef(slice.start, localId)
            || containsLocalRef(slice.end, localId);
    }

    if (auto tmpl = cast(TemplateInstantiationExpression)expr) {
        foreach (arg; tmpl.callArguments)
            if (containsLocalRef(arg, localId)) return true;
        return false;
    }

    if (auto funcLit = cast(FunctionLiteralExpression)expr) {
        if (funcLit.capturedOuterLocalIds !is null) {
            foreach (capturedId; funcLit.capturedOuterLocalIds)
                if (capturedId == localId) return true;
        }
        return false;
    }

    // Literals, TraitsExpression, IsExpression, etc. — no local refs
    return false;
}

// ---------------------------------------------------------------------------
// Phase 3: &local safety warnings
// ---------------------------------------------------------------------------

/// Check if any statement in the function body contains &local in an
/// escape context (return statement, field assignment).
private bool containsAddressOf(Statement stmt) {
    if (stmt is null) return false;

    if (auto compound = cast(CompoundStatement)stmt) {
        foreach (s; compound.statements)
            if (containsAddressOf(s)) return true;
    } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
        if (exprContainsAddressOf(exprStmt.expression)) return true;
    } else if (auto returnStmt = cast(ReturnStatement)stmt) {
        if (returnStmt.value !is null && exprContainsAddressOf(returnStmt.value))
            return true;
    } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
        if (varDecl.initializer !is null && exprContainsAddressOf(varDecl.initializer))
            return true;
    } else if (auto ifStmt = cast(IfStatement)stmt) {
        if (containsAddressOf(ifStmt.thenStatement)) return true;
        if (ifStmt.elseStatement !is null && containsAddressOf(ifStmt.elseStatement))
            return true;
    } else if (auto whileStmt = cast(WhileStatement)stmt) {
        if (containsAddressOf(whileStmt.body_)) return true;
    } else if (auto forStmt = cast(ForStatement)stmt) {
        if (forStmt.init !is null && containsAddressOf(forStmt.init)) return true;
        if (containsAddressOf(forStmt.body_)) return true;
    } else if (auto mixinStmt = cast(MixinStatement)stmt) {
        if (mixinStmt.isExpanded) {
            foreach (s; mixinStmt.expandedStatements)
                if (containsAddressOf(s)) return true;
        }
    } else if (auto tryStmt = cast(TryStatement)stmt) {
        if (containsAddressOf(tryStmt.tryBody)) return true;
        foreach (c; tryStmt.catches)
            if (containsAddressOf(c.body_)) return true;
        if (tryStmt.finallyBody !is null && containsAddressOf(tryStmt.finallyBody))
            return true;
    }
    // BreakStatement, ContinueStatement, StructDeclarationStatement — no address-of

    return false;
}

private bool exprContainsAddressOf(Expression expr) {
    if (expr is null) return false;

    if (auto unary = cast(UnaryExpression)expr) {
        if (unary.operator == UnaryExpression.Operator.AddressOf) return true;
        if (exprContainsAddressOf(unary.operand)) return true;
    }
    if (auto binary = cast(BinaryExpression)expr) {
        if (exprContainsAddressOf(binary.left)) return true;
        if (exprContainsAddressOf(binary.right)) return true;
    }
    if (auto call = cast(CallExpression)expr) {
        foreach (arg; call.arguments)
            if (exprContainsAddressOf(arg)) return true;
    }
    if (auto assign = cast(AssignmentExpression)expr) {
        if (exprContainsAddressOf(assign.right)) return true;
    }
    if (auto castExpr = cast(CastExpression)expr) {
        if (exprContainsAddressOf(castExpr.expression)) return true;
    }
    if (auto throwExpr = cast(ThrowExpression)expr) {
        if (exprContainsAddressOf(throwExpr.operand)) return true;
    }

    return false;
}

/// Walk the function body and emit diagnostics for &local that escapes.
private void checkAddressOfEscapes(Statement stmt, string funcName) {
    if (stmt is null) return;

    if (auto compound = cast(CompoundStatement)stmt) {
        foreach (s; compound.statements)
            checkAddressOfEscapes(s, funcName);
    } else if (auto returnStmt = cast(ReturnStatement)stmt) {
        // return &local → error
        if (returnStmt.value !is null) {
            checkReturnForAddressOfLocal(returnStmt.value, funcName);
        }
    } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
        // obj.field = &local → warning
        checkExprForFieldAddressOfLocal(exprStmt.expression, funcName);
    } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
        // Check initializer for field assignments containing &local
        if (varDecl.initializer !is null)
            checkExprForFieldAddressOfLocal(varDecl.initializer, funcName);
    } else if (auto ifStmt = cast(IfStatement)stmt) {
        checkAddressOfEscapes(ifStmt.thenStatement, funcName);
        if (ifStmt.elseStatement !is null)
            checkAddressOfEscapes(ifStmt.elseStatement, funcName);
    } else if (auto whileStmt = cast(WhileStatement)stmt) {
        checkAddressOfEscapes(whileStmt.body_, funcName);
    } else if (auto forStmt = cast(ForStatement)stmt) {
        if (forStmt.init !is null) checkAddressOfEscapes(forStmt.init, funcName);
        checkAddressOfEscapes(forStmt.body_, funcName);
    } else if (auto mixinStmt = cast(MixinStatement)stmt) {
        if (mixinStmt.isExpanded) {
            foreach (s; mixinStmt.expandedStatements)
                checkAddressOfEscapes(s, funcName);
        }
    } else if (auto tryStmt = cast(TryStatement)stmt) {
        checkAddressOfEscapes(tryStmt.tryBody, funcName);
        foreach (c; tryStmt.catches)
            checkAddressOfEscapes(c.body_, funcName);
        if (tryStmt.finallyBody !is null)
            checkAddressOfEscapes(tryStmt.finallyBody, funcName);
    }
    // BreakStatement, ContinueStatement, StructDeclarationStatement — no-op
}

/// Check if a return value contains &localVar (address of a local).
private void checkReturnForAddressOfLocal(Expression expr, string funcName) {
    if (expr is null) return;

    if (auto unary = cast(UnaryExpression)expr) {
        if (unary.operator == UnaryExpression.Operator.AddressOf) {
            if (auto ident = cast(IdentifierExpression)unary.operand) {
                log(0, "escape-analysis: error: returning address of local variable '",
                    ident.name, "' in function '", funcName, "'");
            }
        }
    }
}

/// Check if an expression stores &localVar in a struct field.
private void checkExprForFieldAddressOfLocal(Expression expr, string funcName) {
    if (expr is null) return;

    if (auto assign = cast(AssignmentExpression)expr) {
        if (cast(MemberExpression)assign.left) {
            // LHS is a field — check if RHS is &local
            if (auto unary = cast(UnaryExpression)assign.right) {
                if (unary.operator == UnaryExpression.Operator.AddressOf) {
                    if (auto ident = cast(IdentifierExpression)unary.operand) {
                        log(0, "escape-analysis: warning: storing address of local variable '",
                            ident.name, "' in struct field in function '", funcName, "'");
                    }
                }
            }
        }
    }
}
