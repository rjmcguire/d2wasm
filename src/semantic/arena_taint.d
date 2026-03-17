/**
 * Arena Memory Safety Analysis
 *
 * Enforces safe-by-default arena memory discipline:
 * 1. Tracks which local variables hold "arena-derived" values (taint analysis)
 * 2. Errors on unsafe stores: tainted values stored into globals or
 *    fields of parameter-received structs (cross-generation escapes)
 * 3. Respects @escapes("paramName") annotations to suppress specific errors
 * 4. Tracks __arena_new()/__arena_drop() sub-generations and detects
 *    use-after-free (reading a variable whose generation was dropped)
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
 * Use-after-free: after __arena_drop(), any tainted variable allocated
 * since the matching __arena_new() is "poisoned". Reading it is an error.
 *
 * Runs after arena analysis (needsArena), before escape analysis.
 * Enabled via --arena-safety CLI flag.
 */
module semantic.arena_taint;

import ast.nodes;
import ast.statements;
import ast.expressions;

import std.format : format;
import diagnostic.log : log;
import diagnostic.error_format : formatError;

import std.stdio : stderr;

/// A single arena safety diagnostic.
private struct ArenaDiagnostic {
    string message;
    SourceLocation location;
}

/// Arena safety error — thrown to stop compilation.
/// All individual errors have already been printed.
class ArenaSafetyError : Exception {
    SourceLocation location;

    this(string message, SourceLocation location,
         string file = __FILE__, size_t line = __LINE__) {
        this.location = location;
        super(message, file, line);
    }
}

/**
 * Entry point: analyze all declarations for arena safety violations.
 */
void analyzeArenaSafety(Declaration[] declarations) {
    ArenaDiagnostic[] allErrors;

    foreach (decl; declarations) {
        if (auto func = cast(FunctionDecl)decl) {
            allErrors ~= analyzeFunction(func, declarations);
        } else if (auto sd = cast(StructDecl)decl) {
            foreach (member; sd.members) {
                if (auto method = cast(FunctionDecl)member) {
                    allErrors ~= analyzeFunction(method, declarations);
                }
            }
        } else if (auto cd = cast(ClassDecl)decl) {
            foreach (member; cd.members) {
                if (auto method = cast(FunctionDecl)member) {
                    allErrors ~= analyzeFunction(method, declarations);
                }
            }
        }
    }

    uint errorCount = cast(uint)allErrors.length;

    if (errorCount > 0) {
        // Print all errors with rustc-style formatting
        foreach (ref diag; allErrors)
            stderr.write(formatError("ArenaSafetyError", diag.message, diag.location));

        throw new ArenaSafetyError(
            format("arena safety: %d error%s found", errorCount, errorCount > 1 ? "s" : ""),
            SourceLocation.init);
    }
}

// ---------------------------------------------------------------------------
// Per-function analysis state
// ---------------------------------------------------------------------------

/// Mutable state threaded through the sequential walk.
private struct AnalysisState {
    bool[uint] tainted;        // uniqueLocalId → true if arena-tainted
    string[uint] localNames;   // uniqueLocalId → variable name (for diagnostics)
    uint[uint] localGeneration; // uniqueLocalId → generation when allocated
    bool[uint] poisoned;       // uniqueLocalId → true if generation was dropped

    uint currentGeneration;    // 0 = base (function-level), incremented by __arena_new
    uint[] generationStack;    // stack of generation IDs for nesting

    uint[string] paramIds;     // parameter name → uniqueLocalId
    string[] escapesParams;    // @escapes parameter names
    string funcName;           // for diagnostics
    Declaration[] declarations; // all declarations (for call target resolution)
    ArenaDiagnostic[] errors;  // collected errors

    uint errorCount() const { return cast(uint)errors.length; }
    bool hasErrors() const { return errors.length > 0; }

    /// Report an arena safety error with location.
    void reportError(string message, SourceLocation loc) {
        errors ~= ArenaDiagnostic(message, loc);
    }

    /// Snapshot for branching (if/else): captures poison state.
    bool[uint] snapshotPoison() {
        bool[uint] copy;
        foreach (k, v; poisoned)
            copy[k] = v;
        return copy;
    }

    /// Merge poison sets from two branches (conservative union).
    void mergePoison(bool[uint] other) {
        foreach (k, v; other)
            poisoned[k] = true;
    }
}

// ---------------------------------------------------------------------------
// Per-function analysis
// ---------------------------------------------------------------------------

/// Returns collected diagnostics.
private ArenaDiagnostic[] analyzeFunction(FunctionDecl func, Declaration[] declarations) {
    if (func.body_ is null || func.isTemplate) return null;

    AnalysisState state;
    state.funcName = func.name;
    state.declarations = declarations;
    state.escapesParams = func.escapesParams;

    // Build parameter ID map
    foreach (p; func.parameters) {
        if (p.uniqueLocalId != uint.max)
            state.paramIds[p.name] = p.uniqueLocalId;
    }

    // Single sequential walk: seed taint, propagate, check stores, track generations
    walkStatement(func.body_, state);

    if (state.tainted.length > 0)
        log(2, "  arena-safety: ", func.name, " has ", state.tainted.length, " tainted locals");

    return state.errors;
}

// ---------------------------------------------------------------------------
// Sequential statement walker
// ---------------------------------------------------------------------------

/**
 * Walk statements in execution order. This handles:
 * - Taint seeding and propagation (Phases 1+2)
 * - Unsafe store detection (Phase 3)
 * - Generation tracking and use-after-free (Phase 4)
 */
private void walkStatement(Statement stmt, ref AnalysisState state) {
    if (stmt is null) return;

    if (auto compound = cast(CompoundStatement)stmt) {
        foreach (s; compound.statements)
            walkStatement(s, state);

    } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
        // Check initializer for use-after-free before processing the declaration
        if (varDecl.initializer !is null)
            checkExprForPoisonedUse(varDecl.initializer, state);

        // Seed taint from initializer
        if (varDecl.uniqueLocalId != uint.max && varDecl.initializer !is null) {
            if (isArenaAllocatingExpr(varDecl.initializer, state)) {
                state.tainted[varDecl.uniqueLocalId] = true;
                state.localNames[varDecl.uniqueLocalId] = varDecl.name;
                state.localGeneration[varDecl.uniqueLocalId] = state.currentGeneration;
                log(2, "  arena-safety: tainted '", varDecl.name,
                    "' (gen ", state.currentGeneration, ")");
            }
        }

    } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
        // Check for __arena_new() / __arena_drop()
        if (auto call = cast(CallExpression)exprStmt.expression) {
            if (auto ident = cast(IdentifierExpression)call.function_) {
                if (ident.name == "__arena_new") {
                    state.currentGeneration++;
                    state.generationStack ~= state.currentGeneration;
                    log(2, "  arena-safety: __arena_new() → generation ",
                        state.currentGeneration);
                    return;
                }
                if (ident.name == "__arena_drop") {
                    if (state.generationStack.length == 0) {
                        state.reportError(
                            format("in '%s', __arena_drop() without matching __arena_new()",
                                state.funcName),
                            exprStmt.location);
                    } else {
                        uint droppedGen = state.generationStack[$ - 1];
                        state.generationStack = state.generationStack[0 .. $ - 1];
                        // Poison all tainted locals from the dropped generation
                        foreach (id, gen; state.localGeneration) {
                            if (gen == droppedGen && id in state.tainted) {
                                state.poisoned[id] = true;
                                log(2, "  arena-safety: poisoned '",
                                    id in state.localNames ? state.localNames[id] : "?",
                                    "' (gen ", droppedGen, " dropped)");
                            }
                        }
                    }
                    log(2, "  arena-safety: __arena_drop() → generation ",
                        state.currentGeneration);
                    return;
                }
            }
        }

        // Check expression for poisoned reads and unsafe stores
        checkExprForPoisonedUse(exprStmt.expression, state);
        checkExprForUnsafeStore(exprStmt.expression, state);

        // Propagate taint through assignments: x = taintedVar
        if (auto assign = cast(AssignmentExpression)exprStmt.expression) {
            if (assign.operator == AssignmentExpression.Operator.Assign) {
                if (auto lhsIdent = cast(IdentifierExpression)assign.left) {
                    if (lhsIdent.resolvedLocalId != uint.max &&
                        lhsIdent.resolvedLocalId !in state.tainted &&
                        exprReferencesAnyTainted(assign.right, state.tainted)) {
                        state.tainted[lhsIdent.resolvedLocalId] = true;
                        state.localNames[lhsIdent.resolvedLocalId] = lhsIdent.name;
                        state.localGeneration[lhsIdent.resolvedLocalId] = state.currentGeneration;
                        log(2, "  arena-safety: tainted '", lhsIdent.name, "' (assignment)");
                    }
                }
            }
        }

    } else if (auto returnStmt = cast(ReturnStatement)stmt) {
        if (returnStmt.value !is null)
            checkExprForPoisonedUse(returnStmt.value, state);

    } else if (auto ifStmt = cast(IfStatement)stmt) {
        // Check condition for poisoned reads
        checkExprForPoisonedUse(ifStmt.condition, state);

        // Walk both branches, merge poison sets (conservative)
        auto beforePoison = state.snapshotPoison();
        walkStatement(ifStmt.thenStatement, state);
        auto thenPoison = state.snapshotPoison();

        if (ifStmt.elseStatement) {
            // Reset to pre-branch state for else
            state.poisoned = beforePoison;
            walkStatement(ifStmt.elseStatement, state);
            // Merge: poisoned if poisoned in EITHER branch
            state.mergePoison(thenPoison);
        } else {
            // No else: merge then-poison with before-poison
            // (the "no else" path doesn't poison anything new)
            state.mergePoison(thenPoison);
        }

    } else if (auto whileStmt = cast(WhileStatement)stmt) {
        checkExprForPoisonedUse(whileStmt.condition, state);
        // Walk body — loop iterations reset at __arena_new()
        walkStatement(whileStmt.body_, state);

    } else if (auto forStmt = cast(ForStatement)stmt) {
        if (forStmt.init)
            walkStatement(forStmt.init, state);
        if (forStmt.condition)
            checkExprForPoisonedUse(forStmt.condition, state);
        // Walk body
        walkStatement(forStmt.body_, state);
        if (forStmt.update)
            checkExprForPoisonedUse(forStmt.update, state);

    } else if (auto tryStmt = cast(TryStatement)stmt) {
        walkStatement(tryStmt.tryBody, state);
        foreach (c; tryStmt.catches)
            walkStatement(c.body_, state);
        if (tryStmt.finallyBody !is null)
            walkStatement(tryStmt.finallyBody, state);

    } else if (auto mixinStmt = cast(MixinStatement)stmt) {
        if (mixinStmt.isExpanded) {
            foreach (s; mixinStmt.expandedStatements)
                walkStatement(s, state);
        }
    }
}

// ---------------------------------------------------------------------------
// Use-after-free detection
// ---------------------------------------------------------------------------

/**
 * Check if an expression reads any poisoned (use-after-free) variable.
 */
private void checkExprForPoisonedUse(Expression expr, ref AnalysisState state) {
    if (expr is null) return;

    if (auto ident = cast(IdentifierExpression)expr) {
        if (ident.resolvedLocalId != uint.max && ident.resolvedLocalId in state.poisoned) {
            string varName = ident.resolvedLocalId in state.localNames
                ? state.localNames[ident.resolvedLocalId] : ident.name;
            state.reportError(
                format("in '%s', use of '%s' after __arena_drop() " ~
                    "— variable was allocated in a dropped arena generation",
                    state.funcName, varName),
                expr.location);
        }
    }
    if (auto member = cast(MemberExpression)expr) {
        checkExprForPoisonedUse(member.object, state);
    }
    if (auto binary = cast(BinaryExpression)expr) {
        checkExprForPoisonedUse(binary.left, state);
        checkExprForPoisonedUse(binary.right, state);
    }
    if (auto unary = cast(UnaryExpression)expr) {
        checkExprForPoisonedUse(unary.operand, state);
    }
    if (auto assign = cast(AssignmentExpression)expr) {
        checkExprForPoisonedUse(assign.right, state);
    }
    if (auto call = cast(CallExpression)expr) {
        if (auto callFunc = cast(MemberExpression)call.function_)
            checkExprForPoisonedUse(callFunc.object, state);
        foreach (arg; call.arguments)
            checkExprForPoisonedUse(arg, state);
    }
    if (auto index = cast(IndexExpression)expr) {
        checkExprForPoisonedUse(index.array, state);
        checkExprForPoisonedUse(index.index, state);
    }
    if (auto cast_ = cast(CastExpression)expr) {
        checkExprForPoisonedUse(cast_.expression, state);
    }
    if (auto slice = cast(SliceExpression)expr) {
        checkExprForPoisonedUse(slice.array, state);
    }
}

// ---------------------------------------------------------------------------
// Taint detection
// ---------------------------------------------------------------------------

/**
 * Check if an expression produces an arena-derived value.
 */
private bool isArenaAllocatingExpr(Expression expr, ref AnalysisState state) {
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
        if (ident.resolvedLocalId != uint.max && ident.resolvedLocalId in state.tainted)
            return true;
    }

    // Return value of a needsArena function
    if (auto call = cast(CallExpression)expr) {
        if (call.resolvedInstantiation !is null && call.resolvedInstantiation.needsArena)
            return true;
        if (auto callTarget = resolveCallTarget(call, state.declarations)) {
            if (callTarget.needsArena)
                return true;
        }
    }

    return false;
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
// Unsafe store detection
// ---------------------------------------------------------------------------

/**
 * Check a single expression for unsafe store patterns.
 */
private void checkExprForUnsafeStore(Expression expr, ref AnalysisState state) {
    if (expr is null) return;

    if (auto assign = cast(AssignmentExpression)expr) {
        // Only check if RHS is tainted
        bool rhsTainted = exprReferencesAnyTainted(assign.right, state.tainted) ||
            assign.operator == AssignmentExpression.Operator.ConcatAssign;
        if (!rhsTainted) return;

        // Rule 1: Storing into a global
        if (auto lhsIdent = cast(IdentifierExpression)assign.left) {
            if (lhsIdent.declaration !is null) {
                if (cast(VariableDecl)lhsIdent.declaration) {
                    state.reportError(
                        format("in '%s', arena-derived value stored into global '%s' " ~
                            "— value may outlive arena generation",
                            state.funcName, lhsIdent.name),
                        assign.location);
                }
            }
        }

        // Rule 2: Storing into a field of a parameter-received struct
        if (auto lhsMember = cast(MemberExpression)assign.left) {
            if (auto objIdent = cast(IdentifierExpression)lhsMember.object) {
                if (auto pId = objIdent.name in state.paramIds) {
                    // Check if @escapes suppresses this
                    bool suppressed = false;
                    if (state.escapesParams !is null) {
                        foreach (ep; state.escapesParams) {
                            if (ep == objIdent.name) {
                                suppressed = true;
                                break;
                            }
                        }
                    }
                    if (!suppressed) {
                        state.reportError(
                            format("in '%s', arena-derived value stored into field '%s' " ~
                                "of parameter '%s' — value may outlive arena generation. " ~
                                "Annotate with @escapes(\"%s\") to allow this",
                                state.funcName, lhsMember.memberName, objIdent.name, objIdent.name),
                            assign.location);
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Resolve a CallExpression to its FunctionDecl target.
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
