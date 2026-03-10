/**
 * Arena Allocation Analyzer
 *
 * Determines which functions need an arena parameter by detecting:
 * 1. Direct allocations: ~= (append), ~ (concat), array literals
 * 2. Transitive allocations: calling a function that needs an arena
 *
 * Sets `FunctionDecl.needsArena = true` on all functions that allocate
 * directly or transitively. Run after type checking, before code generation.
 */
module semantic.arena_analyzer;

import ast.nodes;
import ast.statements;
import ast.expressions;

import std.algorithm;

import diagnostic.log : log;

/**
 * Analyze all declarations and mark functions that need arena allocation.
 */
void analyzeArenaNeeds(Declaration[] declarations) {
    // Phase 1: Mark functions with direct allocations
    foreach (decl; declarations) {
        if (auto func = cast(FunctionDecl)decl) {
            if (func.body_ !is null && !func.isTemplate) {
                if (hasDirectAllocation(func.body_)) {
                    func.needsArena = true;
                }
            }
        }
        // Also check struct/class methods
        if (auto sd = cast(StructDecl)decl) {
            markMethodAllocations(sd);
        }
        if (auto cd = cast(ClassDecl)decl) {
            foreach (member; cd.members) {
                if (auto func = cast(FunctionDecl)member) {
                    if (func.body_ !is null && !func.isTemplate) {
                        if (hasDirectAllocation(func.body_)) {
                            func.needsArena = true;
                        }
                    }
                }
            }
        }
    }

    // Phase 2: Build call graph and propagate transitively
    // Repeat until no changes (fixed-point iteration)
    bool changed = true;
    while (changed) {
        changed = false;
        foreach (decl; declarations) {
            if (auto func = cast(FunctionDecl)decl) {
                if (!func.needsArena && func.body_ !is null && !func.isTemplate) {
                    if (callsAllocatingFunction(func.body_, declarations)) {
                        func.needsArena = true;
                        changed = true;
                    }
                }
            }
            if (auto sd = cast(StructDecl)decl) {
                changed |= propagateMethodAllocations(sd, declarations);
            }
            if (auto cd = cast(ClassDecl)decl) {
                foreach (member; cd.members) {
                    if (auto func = cast(FunctionDecl)member) {
                        if (!func.needsArena && func.body_ !is null && !func.isTemplate) {
                            if (callsAllocatingFunction(func.body_, declarations)) {
                                func.needsArena = true;
                                changed = true;
                            }
                        }
                    }
                }
            }
        }
    }

    // Log results at verbosity 2
    foreach (decl; declarations) {
        if (auto func = cast(FunctionDecl)decl) {
            if (func.needsArena) {
                log(2, "  arena: ", func.name, " (direct or transitive allocation)");
            }
        }
    }
}

private void markMethodAllocations(StructDecl sd) {
    foreach (member; sd.members) {
        if (auto func = cast(FunctionDecl)member) {
            if (func.body_ !is null && !func.isTemplate) {
                if (hasDirectAllocation(func.body_)) {
                    func.needsArena = true;
                }
            }
        }
    }
}

private bool propagateMethodAllocations(StructDecl sd, Declaration[] declarations) {
    bool changed = false;
    foreach (member; sd.members) {
        if (auto func = cast(FunctionDecl)member) {
            if (!func.needsArena && func.body_ !is null && !func.isTemplate) {
                if (callsAllocatingFunction(func.body_, declarations)) {
                    func.needsArena = true;
                    changed = true;
                }
            }
        }
    }
    return changed;
}

/**
 * Check if a statement contains any direct allocation operations.
 */
private bool hasDirectAllocation(Statement stmt) {
    if (stmt is null) return false;

    if (auto compound = cast(CompoundStatement)stmt) {
        foreach (s; compound.statements) {
            if (hasDirectAllocation(s)) return true;
        }
    } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
        if (hasDirectAllocationExpr(exprStmt.expression)) return true;
    } else if (auto returnStmt = cast(ReturnStatement)stmt) {
        if (returnStmt.value && hasDirectAllocationExpr(returnStmt.value)) return true;
    } else if (auto ifStmt = cast(IfStatement)stmt) {
        if (hasDirectAllocationExpr(ifStmt.condition)) return true;
        if (hasDirectAllocation(ifStmt.thenStatement)) return true;
        if (ifStmt.elseStatement && hasDirectAllocation(ifStmt.elseStatement)) return true;
    } else if (auto whileStmt = cast(WhileStatement)stmt) {
        if (hasDirectAllocationExpr(whileStmt.condition)) return true;
        if (hasDirectAllocation(whileStmt.body_)) return true;
    } else if (auto forStmt = cast(ForStatement)stmt) {
        if (forStmt.init && hasDirectAllocation(forStmt.init)) return true;
        if (forStmt.condition && hasDirectAllocationExpr(forStmt.condition)) return true;
        if (forStmt.update && hasDirectAllocationExpr(forStmt.update)) return true;
        if (hasDirectAllocation(forStmt.body_)) return true;
    } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
        if (varDecl.initializer) {
            // Static array init from array literal is just stack stores, not heap allocation
            bool isStaticArrayInit = false;
            if (varDecl.type) {
                if (auto at = cast(ArrayType)varDecl.type) {
                    if (at.isStaticArray && cast(ArrayLiteralExpression)varDecl.initializer)
                        isStaticArrayInit = true;
                }
            }
            if (!isStaticArrayInit && hasDirectAllocationExpr(varDecl.initializer))
                return true;
        }
    } else if (auto mixinStmt = cast(MixinStatement)stmt) {
        if (mixinStmt.isExpanded) {
            foreach (s; mixinStmt.expandedStatements) {
                if (hasDirectAllocation(s)) return true;
            }
        }
    } else if (auto structStmt = cast(StructDeclarationStatement)stmt) {
        // Inner struct methods don't affect the enclosing function's needsArena
    } else if (auto tryStmt = cast(TryStatement)stmt) {
        if (hasDirectAllocation(tryStmt.tryBody)) return true;
        foreach (c; tryStmt.catches)
            if (hasDirectAllocation(c.body_)) return true;
        if (tryStmt.finallyBody !is null && hasDirectAllocation(tryStmt.finallyBody))
            return true;
    }

    return false;
}

/**
 * Check if an expression contains a direct allocation operation.
 * Direct allocations: ~= (concat assign), ~ (concat), array literals
 */
private bool hasDirectAllocationExpr(Expression expr) {
    if (expr is null) return false;

    if (auto assign = cast(AssignmentExpression)expr) {
        if (assign.operator == AssignmentExpression.Operator.ConcatAssign) return true;
        if (hasDirectAllocationExpr(assign.left)) return true;
        if (hasDirectAllocationExpr(assign.right)) return true;
    } else if (auto binary = cast(BinaryExpression)expr) {
        if (binary.operator == BinaryExpression.Operator.Concat) return true;
        if (hasDirectAllocationExpr(binary.left)) return true;
        if (hasDirectAllocationExpr(binary.right)) return true;
    } else if (cast(ArrayLiteralExpression)expr) {
        return true;
    } else if (auto call = cast(CallExpression)expr) {
        foreach (arg; call.arguments) {
            if (hasDirectAllocationExpr(arg)) return true;
        }
    } else if (auto unary = cast(UnaryExpression)expr) {
        if (hasDirectAllocationExpr(unary.operand)) return true;
    } else if (auto index = cast(IndexExpression)expr) {
        if (hasDirectAllocationExpr(index.array)) return true;
        if (hasDirectAllocationExpr(index.index)) return true;
    } else if (auto member = cast(MemberExpression)expr) {
        if (hasDirectAllocationExpr(member.object)) return true;
    } else if (auto cast_ = cast(CastExpression)expr) {
        if (hasDirectAllocationExpr(cast_.expression)) return true;
    } else if (auto slice = cast(SliceExpression)expr) {
        if (hasDirectAllocationExpr(slice.array)) return true;
        if (hasDirectAllocationExpr(slice.start)) return true;
        if (hasDirectAllocationExpr(slice.end)) return true;
    } else if (auto throwExpr = cast(ThrowExpression)expr) {
        if (hasDirectAllocationExpr(throwExpr.operand)) return true;
    }

    return false;
}

/**
 * Check if a statement calls any function that has needsArena set.
 */
private bool callsAllocatingFunction(Statement stmt, Declaration[] declarations) {
    if (stmt is null) return false;

    if (auto compound = cast(CompoundStatement)stmt) {
        foreach (s; compound.statements) {
            if (callsAllocatingFunction(s, declarations)) return true;
        }
    } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
        if (callsAllocatingFunctionExpr(exprStmt.expression, declarations)) return true;
    } else if (auto returnStmt = cast(ReturnStatement)stmt) {
        if (returnStmt.value && callsAllocatingFunctionExpr(returnStmt.value, declarations)) return true;
    } else if (auto ifStmt = cast(IfStatement)stmt) {
        if (callsAllocatingFunctionExpr(ifStmt.condition, declarations)) return true;
        if (callsAllocatingFunction(ifStmt.thenStatement, declarations)) return true;
        if (ifStmt.elseStatement && callsAllocatingFunction(ifStmt.elseStatement, declarations)) return true;
    } else if (auto whileStmt = cast(WhileStatement)stmt) {
        if (callsAllocatingFunctionExpr(whileStmt.condition, declarations)) return true;
        if (callsAllocatingFunction(whileStmt.body_, declarations)) return true;
    } else if (auto forStmt = cast(ForStatement)stmt) {
        if (forStmt.init && callsAllocatingFunction(forStmt.init, declarations)) return true;
        if (forStmt.condition && callsAllocatingFunctionExpr(forStmt.condition, declarations)) return true;
        if (forStmt.update && callsAllocatingFunctionExpr(forStmt.update, declarations)) return true;
        if (callsAllocatingFunction(forStmt.body_, declarations)) return true;
    } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
        if (varDecl.initializer && callsAllocatingFunctionExpr(varDecl.initializer, declarations)) return true;
    } else if (auto mixinStmt = cast(MixinStatement)stmt) {
        if (mixinStmt.isExpanded) {
            foreach (s; mixinStmt.expandedStatements) {
                if (callsAllocatingFunction(s, declarations)) return true;
            }
        }
    } else if (auto tryStmt = cast(TryStatement)stmt) {
        if (callsAllocatingFunction(tryStmt.tryBody, declarations)) return true;
        foreach (c; tryStmt.catches)
            if (callsAllocatingFunction(c.body_, declarations)) return true;
        if (tryStmt.finallyBody !is null && callsAllocatingFunction(tryStmt.finallyBody, declarations))
            return true;
    }

    return false;
}

/**
 * Check if an expression calls a function that has needsArena set.
 */
private bool callsAllocatingFunctionExpr(Expression expr, Declaration[] declarations) {
    if (expr is null) return false;

    if (auto call = cast(CallExpression)expr) {
        // Check if this call targets an allocating function
        if (auto target = resolveCallTarget(call, declarations)) {
            if (target.needsArena) return true;
        }
        // Also check IFTI instantiations
        if (call.resolvedInstantiation !is null && call.resolvedInstantiation.needsArena) {
            return true;
        }
        // Check arguments recursively
        foreach (arg; call.arguments) {
            if (callsAllocatingFunctionExpr(arg, declarations)) return true;
        }
    } else if (auto binary = cast(BinaryExpression)expr) {
        if (callsAllocatingFunctionExpr(binary.left, declarations)) return true;
        if (callsAllocatingFunctionExpr(binary.right, declarations)) return true;
        if (binary.loweredCall && callsAllocatingFunctionExpr(binary.loweredCall, declarations)) return true;
    } else if (auto assign = cast(AssignmentExpression)expr) {
        if (callsAllocatingFunctionExpr(assign.left, declarations)) return true;
        if (callsAllocatingFunctionExpr(assign.right, declarations)) return true;
        if (assign.loweredCall && callsAllocatingFunctionExpr(assign.loweredCall, declarations)) return true;
    } else if (auto unary = cast(UnaryExpression)expr) {
        if (callsAllocatingFunctionExpr(unary.operand, declarations)) return true;
    } else if (auto index = cast(IndexExpression)expr) {
        if (callsAllocatingFunctionExpr(index.array, declarations)) return true;
        if (callsAllocatingFunctionExpr(index.index, declarations)) return true;
    } else if (auto member = cast(MemberExpression)expr) {
        if (callsAllocatingFunctionExpr(member.object, declarations)) return true;
    } else if (auto cast_ = cast(CastExpression)expr) {
        if (callsAllocatingFunctionExpr(cast_.expression, declarations)) return true;
    } else if (auto slice = cast(SliceExpression)expr) {
        if (callsAllocatingFunctionExpr(slice.array, declarations)) return true;
        if (callsAllocatingFunctionExpr(slice.start, declarations)) return true;
        if (callsAllocatingFunctionExpr(slice.end, declarations)) return true;
    } else if (auto tmpl = cast(TemplateInstantiationExpression)expr) {
        if (tmpl.resolvedInstantiation !is null && tmpl.resolvedInstantiation.needsArena) return true;
        foreach (arg; tmpl.callArguments) {
            if (callsAllocatingFunctionExpr(arg, declarations)) return true;
        }
    } else if (auto throwExpr = cast(ThrowExpression)expr) {
        if (callsAllocatingFunctionExpr(throwExpr.operand, declarations)) return true;
    }

    return false;
}

/**
 * Resolve a CallExpression to its FunctionDecl target.
 * Returns null for builtins, intrinsics, or unresolved calls.
 */
private FunctionDecl resolveCallTarget(CallExpression call, Declaration[] declarations) {
    // Direct function call: foo()
    if (auto ident = cast(IdentifierExpression)call.function_) {
        string funcName = ident.name;

        // Skip builtins/intrinsics (start with __)
        if (funcName.length >= 2 && funcName[0 .. 2] == "__") return null;

        foreach (decl; declarations) {
            if (auto func = cast(FunctionDecl)decl) {
                if (func.name == funcName && func.body_ !is null) return func;
            }
        }
        // Check again for forward declarations
        foreach (decl; declarations) {
            if (auto func = cast(FunctionDecl)decl) {
                if (func.name == funcName) return func;
            }
        }
    }

    // Method call: obj.method() — check struct methods and UFCS free functions
    if (auto member = cast(MemberExpression)call.function_) {
        string methodName = member.memberName;
        // Struct/class methods
        foreach (decl; declarations) {
            if (auto sd = cast(StructDecl)decl) {
                foreach (m; sd.members) {
                    if (auto func = cast(FunctionDecl)m) {
                        if (func.name == methodName && func.isMethod) return func;
                    }
                }
            }
        }
        // UFCS: obj.func() → func(obj) — search free functions by name
        foreach (decl; declarations) {
            if (auto func = cast(FunctionDecl)decl) {
                if (func.name == methodName && func.body_ !is null) return func;
            }
        }
    }

    return null;
}
