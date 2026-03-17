/**
 * Arena Memory Safety Analysis
 *
 * Enforces safe-by-default arena memory discipline:
 * 1. Tracks which local variables hold "arena-derived" values (taint analysis)
 * 2. Errors on unsafe stores: tainted values stored into globals or
 *    fields of parameter-received structs (cross-generation escapes)
 * 3. Respects @escapes("paramName") annotations to suppress specific errors
 *
 * A variable is "arena-tainted" if it:
 *   - Is initialized from a `new` expression
 *   - Is initialized from an array literal, concat (~), or append (~=)
 *   - Is assigned from another tainted variable
 *   - Captures the return value of a function with needsArena
 *
 * Safe operations (no annotation needed):
 *   - Returning arena-derived values (parent owns the arena generation)
 *   - Passing arena-derived values to callees (callee dies before parent)
 *   - Storing into local variables (die with the function)
 *
 * Unsafe operations (require @escapes annotation):
 *   - Storing into a global variable
 *   - Storing into a field of a parameter-received struct/class
 *
 * Runs after arena analysis (needsArena), before escape analysis.
 * Enabled via --arena-safety CLI flag.
 */
module semantic.arena_taint;

import ast.nodes;
import ast.statements;
import ast.expressions;

import diagnostic.log : log;

/**
 * Entry point: analyze all declarations for arena safety violations.
 */
void analyzeArenaSafety(Declaration[] declarations) {
    foreach (decl; declarations) {
        if (auto func = cast(FunctionDecl)decl) {
            analyzeFunction(func, declarations);
        } else if (auto sd = cast(StructDecl)decl) {
            foreach (member; sd.members) {
                if (auto method = cast(FunctionDecl)member) {
                    analyzeFunction(method, declarations);
                }
            }
        } else if (auto cd = cast(ClassDecl)decl) {
            foreach (member; cd.members) {
                if (auto method = cast(FunctionDecl)member) {
                    analyzeFunction(method, declarations);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Per-function analysis
// ---------------------------------------------------------------------------

private void analyzeFunction(FunctionDecl func, Declaration[] declarations) {
    if (func.body_ is null || func.isTemplate) return;

    // Phase 1: Seed tainted locals from direct allocations
    bool[uint] tainted;       // uniqueLocalId → true if arena-tainted
    string[uint] localNames;  // uniqueLocalId → variable name (for diagnostics)
    collectTaintedLocals(func.body_, tainted, localNames, declarations);

    // Phase 2: Propagate taint through assignments (fixed-point)
    bool changed = true;
    while (changed) {
        changed = false;
        propagateTaint(func.body_, tainted, localNames, changed);
    }

    if (tainted.length == 0) return;

    log(2, "  arena-safety: ", func.name, " has ", tainted.length, " tainted locals");

    // Build set of parameter uniqueLocalIds and names
    uint[string] paramIds;   // name → uniqueLocalId
    foreach (p; func.parameters) {
        if (p.uniqueLocalId != uint.max) {
            paramIds[p.name] = p.uniqueLocalId;
        }
    }

    // Phase 3: Check for unsafe stores
    checkUnsafeStores(func.body_, tainted, paramIds, func.escapesParams, func.name);
}

// ---------------------------------------------------------------------------
// Phase 1: Seed tainted locals
// ---------------------------------------------------------------------------

/**
 * Walk function body and find locals initialized from arena-allocating expressions.
 */
private void collectTaintedLocals(Statement stmt, ref bool[uint] tainted,
        ref string[uint] localNames, Declaration[] declarations) {
    if (stmt is null) return;

    if (auto compound = cast(CompoundStatement)stmt) {
        foreach (s; compound.statements)
            collectTaintedLocals(s, tainted, localNames, declarations);
    } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
        if (varDecl.uniqueLocalId != uint.max && varDecl.initializer !is null) {
            if (isArenaAllocatingExpr(varDecl.initializer, tainted, declarations)) {
                tainted[varDecl.uniqueLocalId] = true;
                localNames[varDecl.uniqueLocalId] = varDecl.name;
                log(2, "  arena-safety: tainted '", varDecl.name, "' (direct allocation)");
            }
        }
    } else if (auto ifStmt = cast(IfStatement)stmt) {
        collectTaintedLocals(ifStmt.thenStatement, tainted, localNames, declarations);
        if (ifStmt.elseStatement)
            collectTaintedLocals(ifStmt.elseStatement, tainted, localNames, declarations);
    } else if (auto whileStmt = cast(WhileStatement)stmt) {
        collectTaintedLocals(whileStmt.body_, tainted, localNames, declarations);
    } else if (auto forStmt = cast(ForStatement)stmt) {
        if (forStmt.init)
            collectTaintedLocals(forStmt.init, tainted, localNames, declarations);
        collectTaintedLocals(forStmt.body_, tainted, localNames, declarations);
    } else if (auto tryStmt = cast(TryStatement)stmt) {
        collectTaintedLocals(tryStmt.tryBody, tainted, localNames, declarations);
        foreach (c; tryStmt.catches)
            collectTaintedLocals(c.body_, tainted, localNames, declarations);
        if (tryStmt.finallyBody !is null)
            collectTaintedLocals(tryStmt.finallyBody, tainted, localNames, declarations);
    } else if (auto mixinStmt = cast(MixinStatement)stmt) {
        if (mixinStmt.isExpanded) {
            foreach (s; mixinStmt.expandedStatements)
                collectTaintedLocals(s, tainted, localNames, declarations);
        }
    }
    // ExpressionStatement, ReturnStatement, etc. don't declare locals
}

/**
 * Check if an expression produces an arena-derived value.
 */
private bool isArenaAllocatingExpr(Expression expr, ref bool[uint] tainted, Declaration[] declarations) {
    if (expr is null) return false;

    // Direct allocations
    if (cast(NewExpression)expr) return true;
    if (cast(ArrayLiteralExpression)expr) return true;

    // Concat / append produce new arena allocations
    if (auto binary = cast(BinaryExpression)expr) {
        if (binary.operator == BinaryExpression.Operator.Concat) return true;
    }
    if (auto assign = cast(AssignmentExpression)expr) {
        if (assign.operator == AssignmentExpression.Operator.ConcatAssign) return true;
    }

    // Assigned from another tainted local
    if (auto ident = cast(IdentifierExpression)expr) {
        if (ident.resolvedLocalId != uint.max && ident.resolvedLocalId in tainted)
            return true;
    }

    // Return value of a needsArena function
    if (auto call = cast(CallExpression)expr) {
        if (call.resolvedInstantiation !is null && call.resolvedInstantiation.needsArena)
            return true;
        if (auto callTarget = resolveCallTarget(call, declarations)) {
            if (callTarget.needsArena)
                return true;
        }
    }

    return false;
}

// ---------------------------------------------------------------------------
// Phase 2: Propagate taint through assignments
// ---------------------------------------------------------------------------

/**
 * Scan assignments where RHS references a tainted local → taint the LHS local.
 */
private void propagateTaint(Statement stmt, ref bool[uint] tainted,
        ref string[uint] localNames, ref bool changed) {
    if (stmt is null) return;

    if (auto compound = cast(CompoundStatement)stmt) {
        foreach (s; compound.statements)
            propagateTaint(s, tainted, localNames, changed);
    } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
        // Already handled in Phase 1 for initial values, but check
        // if initializer references a tainted local (transitive)
        if (varDecl.uniqueLocalId != uint.max &&
            varDecl.uniqueLocalId !in tainted &&
            varDecl.initializer !is null) {
            if (exprReferencesAnyTainted(varDecl.initializer, tainted)) {
                tainted[varDecl.uniqueLocalId] = true;
                localNames[varDecl.uniqueLocalId] = varDecl.name;
                log(2, "  arena-safety: tainted '", varDecl.name, "' (transitive)");
                changed = true;
            }
        }
    } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
        // Check x = taintedVar assignments
        if (auto assign = cast(AssignmentExpression)exprStmt.expression) {
            if (assign.operator == AssignmentExpression.Operator.Assign) {
                if (auto lhsIdent = cast(IdentifierExpression)assign.left) {
                    if (lhsIdent.resolvedLocalId != uint.max &&
                        lhsIdent.resolvedLocalId !in tainted &&
                        exprReferencesAnyTainted(assign.right, tainted)) {
                        tainted[lhsIdent.resolvedLocalId] = true;
                        localNames[lhsIdent.resolvedLocalId] = lhsIdent.name;
                        log(2, "  arena-safety: tainted '", lhsIdent.name, "' (assignment)");
                        changed = true;
                    }
                }
            }
        }
    } else if (auto ifStmt = cast(IfStatement)stmt) {
        propagateTaint(ifStmt.thenStatement, tainted, localNames, changed);
        if (ifStmt.elseStatement)
            propagateTaint(ifStmt.elseStatement, tainted, localNames, changed);
    } else if (auto whileStmt = cast(WhileStatement)stmt) {
        propagateTaint(whileStmt.body_, tainted, localNames, changed);
    } else if (auto forStmt = cast(ForStatement)stmt) {
        if (forStmt.init)
            propagateTaint(forStmt.init, tainted, localNames, changed);
        propagateTaint(forStmt.body_, tainted, localNames, changed);
    } else if (auto tryStmt = cast(TryStatement)stmt) {
        propagateTaint(tryStmt.tryBody, tainted, localNames, changed);
        foreach (c; tryStmt.catches)
            propagateTaint(c.body_, tainted, localNames, changed);
        if (tryStmt.finallyBody !is null)
            propagateTaint(tryStmt.finallyBody, tainted, localNames, changed);
    } else if (auto mixinStmt = cast(MixinStatement)stmt) {
        if (mixinStmt.isExpanded) {
            foreach (s; mixinStmt.expandedStatements)
                propagateTaint(s, tainted, localNames, changed);
        }
    }
}

/**
 * Check if an expression references any tainted local variable.
 */
private bool exprReferencesAnyTainted(Expression expr, ref bool[uint] tainted) {
    if (expr is null) return false;

    if (auto ident = cast(IdentifierExpression)expr) {
        return ident.resolvedLocalId != uint.max && ident.resolvedLocalId in tainted;
    }
    if (auto member = cast(MemberExpression)expr) {
        return exprReferencesAnyTainted(member.object, tainted);
    }
    if (auto binary = cast(BinaryExpression)expr) {
        return exprReferencesAnyTainted(binary.left, tainted) ||
               exprReferencesAnyTainted(binary.right, tainted);
    }
    if (auto unary = cast(UnaryExpression)expr) {
        return exprReferencesAnyTainted(unary.operand, tainted);
    }
    if (auto cast_ = cast(CastExpression)expr) {
        return exprReferencesAnyTainted(cast_.expression, tainted);
    }
    if (auto index = cast(IndexExpression)expr) {
        return exprReferencesAnyTainted(index.array, tainted);
    }
    if (auto call = cast(CallExpression)expr) {
        foreach (arg; call.arguments)
            if (exprReferencesAnyTainted(arg, tainted)) return true;
    }

    return false;
}

// ---------------------------------------------------------------------------
// Phase 3: Check for unsafe stores
// ---------------------------------------------------------------------------

import std.format : format;

/**
 * Walk function body looking for assignments that store tainted values
 * into globals or parameter-received struct fields.
 */
private void checkUnsafeStores(Statement stmt, ref bool[uint] tainted,
        ref uint[string] paramIds, string[] escapesParams, string funcName) {
    if (stmt is null) return;

    if (auto compound = cast(CompoundStatement)stmt) {
        foreach (s; compound.statements)
            checkUnsafeStores(s, tainted, paramIds, escapesParams, funcName);
    } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
        checkExprForUnsafeStore(exprStmt.expression, tainted, paramIds, escapesParams, funcName);
    } else if (auto ifStmt = cast(IfStatement)stmt) {
        checkUnsafeStores(ifStmt.thenStatement, tainted, paramIds, escapesParams, funcName);
        if (ifStmt.elseStatement)
            checkUnsafeStores(ifStmt.elseStatement, tainted, paramIds, escapesParams, funcName);
    } else if (auto whileStmt = cast(WhileStatement)stmt) {
        checkUnsafeStores(whileStmt.body_, tainted, paramIds, escapesParams, funcName);
    } else if (auto forStmt = cast(ForStatement)stmt) {
        if (forStmt.init)
            checkUnsafeStores(forStmt.init, tainted, paramIds, escapesParams, funcName);
        checkUnsafeStores(forStmt.body_, tainted, paramIds, escapesParams, funcName);
    } else if (auto tryStmt = cast(TryStatement)stmt) {
        checkUnsafeStores(tryStmt.tryBody, tainted, paramIds, escapesParams, funcName);
        foreach (c; tryStmt.catches)
            checkUnsafeStores(c.body_, tainted, paramIds, escapesParams, funcName);
        if (tryStmt.finallyBody !is null)
            checkUnsafeStores(tryStmt.finallyBody, tainted, paramIds, escapesParams, funcName);
    } else if (auto mixinStmt = cast(MixinStatement)stmt) {
        if (mixinStmt.isExpanded) {
            foreach (s; mixinStmt.expandedStatements)
                checkUnsafeStores(s, tainted, paramIds, escapesParams, funcName);
        }
    }
}

/**
 * Check a single expression for unsafe store patterns.
 */
private void checkExprForUnsafeStore(Expression expr, ref bool[uint] tainted,
        ref uint[string] paramIds, string[] escapesParams, string funcName) {
    if (expr is null) return;

    if (auto assign = cast(AssignmentExpression)expr) {
        // Only check if RHS is tainted
        if (!exprReferencesAnyTainted(assign.right, tainted) &&
            assign.operator != AssignmentExpression.Operator.ConcatAssign)
            return;

        // For ~= the LHS itself is the target being modified with arena data
        bool rhsTainted = exprReferencesAnyTainted(assign.right, tainted) ||
            assign.operator == AssignmentExpression.Operator.ConcatAssign;
        if (!rhsTainted) return;

        // Rule 1: Storing into a global
        if (auto lhsIdent = cast(IdentifierExpression)assign.left) {
            if (lhsIdent.declaration !is null) {
                if (cast(VariableDecl)lhsIdent.declaration) {
                    // VariableDecl = top-level/global variable declaration
                    import ast.nodes : SourceLocation;
                    log(0, format("arena-safety error: in '%s', arena-derived value " ~
                        "stored into global '%s' — value may outlive arena generation",
                        funcName, lhsIdent.name));
                    if (assign.location != SourceLocation.init)
                        log(0, format("  at %s:%d:%d",
                            assign.location.filename, assign.location.line, assign.location.column));
                }
            }
        }

        // Rule 2: Storing into a field of a parameter-received struct
        if (auto lhsMember = cast(MemberExpression)assign.left) {
            if (auto objIdent = cast(IdentifierExpression)lhsMember.object) {
                // Check if the object is a function parameter
                if (auto pId = objIdent.name in paramIds) {
                    // Check if @escapes suppresses this
                    bool suppressed = false;
                    if (escapesParams !is null) {
                        foreach (ep; escapesParams) {
                            if (ep == objIdent.name) {
                                suppressed = true;
                                break;
                            }
                        }
                    }
                    if (!suppressed) {
                        import ast.nodes : SourceLocation;
                        log(0, format("arena-safety error: in '%s', arena-derived value " ~
                            "stored into field '%s' of parameter '%s' — " ~
                            "value may outlive arena generation. " ~
                            "Annotate with @escapes(\"%s\") to allow this",
                            funcName, lhsMember.memberName, objIdent.name, objIdent.name));
                        if (assign.location != SourceLocation.init)
                            log(0, format("  at %s:%d:%d",
                                assign.location.filename, assign.location.line, assign.location.column));
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers (reuse arena_analyzer patterns)
// ---------------------------------------------------------------------------

/**
 * Resolve a CallExpression to its FunctionDecl target.
 * Replicates arena_analyzer.resolveCallTarget logic.
 */
private FunctionDecl resolveCallTarget(CallExpression call, Declaration[] declarations) {
    if (auto ident = cast(IdentifierExpression)call.function_) {
        string funcName = ident.name;
        if (funcName.length >= 2 && funcName[0 .. 2] == "__") return null;

        foreach (decl; declarations) {
            if (auto func = cast(FunctionDecl)decl) {
                if (func.name == funcName && func.body_ !is null) return func;
            }
        }
        foreach (decl; declarations) {
            if (auto func = cast(FunctionDecl)decl) {
                if (func.name == funcName) return func;
            }
        }
    }

    if (auto member = cast(MemberExpression)call.function_) {
        string methodName = member.memberName;
        foreach (decl; declarations) {
            if (auto sd = cast(StructDecl)decl) {
                foreach (m; sd.members) {
                    if (auto func = cast(FunctionDecl)m) {
                        if (func.name == methodName && func.isMethod) return func;
                    }
                }
            }
        }
        foreach (decl; declarations) {
            if (auto func = cast(FunctionDecl)decl) {
                if (func.name == methodName && func.body_ !is null) return func;
            }
        }
    }

    return null;
}
