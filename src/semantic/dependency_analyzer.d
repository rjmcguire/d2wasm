/**
 * Dependency Analyzer for CTFE
 *
 * Finds the transitive closure of function calls for a given entry function.
 * Used to compile all required functions together into a single CTFE module.
 */
module semantic.dependency_analyzer;

import ast.nodes;
import ast.statements;
import ast.expressions;
import semantic.symbol_table;

import std.algorithm;
import std.array;

/**
 * Analyzes function dependencies for CTFE compilation.
 */
class DependencyAnalyzer {
    private SymbolTable symbolTable;
    private Declaration[] allDeclarations;

    // Track visited functions to handle cycles
    private bool[string] visited;
    private bool[string] inProgress;  // For cycle detection in manifest constants

    // Struct declarations needed for method compilation
    private bool[string] neededStructs;
    private StructDecl[] structDeps;

    this(SymbolTable symbolTable, Declaration[] declarations) {
        this.symbolTable = symbolTable;
        this.allDeclarations = declarations;
    }

    /**
     * Find all functions that the entry function depends on (transitive closure).
     * Returns array including the entry function itself.
     */
    FunctionDecl[] findDependencies(FunctionDecl entryFunc) {
        visited.clear();
        inProgress.clear();
        neededStructs.clear();
        structDeps = null;

        FunctionDecl[] result;
        collectDependencies(entryFunc, result);
        return result;
    }

    /**
     * Get struct declarations needed for method compilation.
     * Call after findDependencies().
     */
    StructDecl[] getStructDependencies() {
        return structDeps;
    }

    /// Compute a unique key for a function (D ABI mangled name for methods).
    private static string funcKey(FunctionDecl func) {
        import codegen.mangle : computeMangledName;
        if (func.isMethod && func.parent !is null)
            return computeMangledName([], func);
        return func.name;
    }

    private void collectDependencies(FunctionDecl func, ref FunctionDecl[] result) {
        string key = funcKey(func);
        if (key in visited) {
            return;  // Already processed
        }

        visited[key] = true;
        result ~= func;

        // If this is a struct method, track the parent struct
        if (func.isMethod && func.parent !is null) {
            if (auto sd = cast(StructDecl)func.parent) {
                if (sd.name !in neededStructs) {
                    neededStructs[sd.name] = true;
                    structDeps ~= sd;
                }
            }
        }

        // Find all calls and template instantiations in this function's body
        auto calls = findCallsInStatement(func.body_);
        auto tmplCalls = findTemplateCallsInStatement(func.body_);

        // Process template instantiations first — struct deps must be known
        // before resolveFunction searches them for method calls
        foreach (tmplCall; tmplCalls) {
            if (tmplCall.resolvedStructInstantiation !is null) {
                auto sd = tmplCall.resolvedStructInstantiation;
                if (sd.name !in neededStructs) {
                    neededStructs[sd.name] = true;
                    structDeps ~= sd;
                }
            }
            if (tmplCall.resolvedInstantiation !is null) {
                collectDependencies(tmplCall.resolvedInstantiation, result);
            }
        }

        // Scan variable declarations for struct types (including template instantiations
        // in type position like `Sized!(3) s;` which aren't TemplateInstantiationExpressions)
        collectStructDepsFromStatements(func.body_);

        // Collect all virtual methods from class-typed parameters and local variables.
        // Virtual dispatch requires ALL methods of a class to be compiled, not just
        // the ones directly called (overrides may be invoked at runtime).
        collectClassMethodDeps(func, result);

        foreach (call; calls) {
            // Try to resolve the call to a FunctionDecl
            auto calledFunc = resolveFunction(call);
            if (calledFunc !is null) {
                collectDependencies(calledFunc, result);
            }
        }

        // Follow IFTI resolved instantiations on regular CallExpressions
        foreach (call; calls) {
            if (call.resolvedInstantiation !is null) {
                collectDependencies(call.resolvedInstantiation, result);
            }
        }
    }

    /**
     * Find all CallExpressions in a statement (recursive).
     */
    private CallExpression[] findCallsInStatement(Statement stmt) {
        CallExpression[] calls;

        if (stmt is null) return calls;

        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                calls ~= findCallsInStatement(s);
            }
        } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
            calls ~= findCallsInExpression(exprStmt.expression);
        } else if (auto returnStmt = cast(ReturnStatement)stmt) {
            if (returnStmt.value) {
                calls ~= findCallsInExpression(returnStmt.value);
            }
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            calls ~= findCallsInExpression(ifStmt.condition);
            calls ~= findCallsInStatement(ifStmt.thenStatement);
            if (ifStmt.elseStatement) {
                calls ~= findCallsInStatement(ifStmt.elseStatement);
            }
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            calls ~= findCallsInExpression(whileStmt.condition);
            calls ~= findCallsInStatement(whileStmt.body_);
        } else if (auto forStmt = cast(ForStatement)stmt) {
            if (forStmt.init) {
                calls ~= findCallsInStatement(forStmt.init);
            }
            if (forStmt.condition) {
                calls ~= findCallsInExpression(forStmt.condition);
            }
            if (forStmt.update) {
                calls ~= findCallsInExpression(forStmt.update);
            }
            calls ~= findCallsInStatement(forStmt.body_);
        } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
            if (varDecl.initializer) {
                calls ~= findCallsInExpression(varDecl.initializer);
            }
        } else if (auto mixinStmt = cast(MixinStatement)stmt) {
            if (mixinStmt.isExpanded) {
                foreach (s; mixinStmt.expandedStatements) {
                    calls ~= findCallsInStatement(s);
                }
            }
        } else if (auto structStmt = cast(StructDeclarationStatement)stmt) {
            // Scan inner struct method bodies for calls
            foreach (member; structStmt.structDecl.members) {
                if (auto funcDecl = cast(FunctionDecl)member) {
                    if (funcDecl.body_) {
                        calls ~= findCallsInStatement(funcDecl.body_);
                    }
                }
            }
        }
        // Note: AssignmentStatement doesn't exist - assignments are expressions

        return calls;
    }

    /**
     * Find all CallExpressions in an expression (recursive).
     */
    private CallExpression[] findCallsInExpression(Expression expr) {
        CallExpression[] calls;

        if (expr is null) return calls;

        if (auto call = cast(CallExpression)expr) {
            calls ~= call;
            // Also check arguments for nested calls
            foreach (arg; call.arguments) {
                calls ~= findCallsInExpression(arg);
            }
        } else if (auto binary = cast(BinaryExpression)expr) {
            calls ~= findCallsInExpression(binary.left);
            calls ~= findCallsInExpression(binary.right);
            // Follow lowered shift operator calls
            if (binary.loweredCall)
                calls ~= findCallsInExpression(binary.loweredCall);
        } else if (auto unary = cast(UnaryExpression)expr) {
            calls ~= findCallsInExpression(unary.operand);
            if (unary.loweredCall)
                calls ~= findCallsInExpression(unary.loweredCall);
        } else if (auto index = cast(IndexExpression)expr) {
            calls ~= findCallsInExpression(index.array);
            calls ~= findCallsInExpression(index.index);
        } else if (auto member = cast(MemberExpression)expr) {
            calls ~= findCallsInExpression(member.object);
        } else if (auto arrayLit = cast(ArrayLiteralExpression)expr) {
            foreach (elem; arrayLit.elements) {
                calls ~= findCallsInExpression(elem);
            }
        } else if (auto cast_ = cast(CastExpression)expr) {
            calls ~= findCallsInExpression(cast_.expression);
        } else if (auto assign = cast(AssignmentExpression)expr) {
            calls ~= findCallsInExpression(assign.left);
            calls ~= findCallsInExpression(assign.right);
            if (assign.loweredCall)
                calls ~= findCallsInExpression(assign.loweredCall);
        } else if (auto slice = cast(SliceExpression)expr) {
            calls ~= findCallsInExpression(slice.array);
            calls ~= findCallsInExpression(slice.start);
            calls ~= findCallsInExpression(slice.end);
        }
        // IdentifierExpression, LiteralExpression, ImportExpression - no calls inside

        return calls;
    }

    /// Find all TemplateInstantiationExpressions in a statement (recursive).
    private TemplateInstantiationExpression[] findTemplateCallsInStatement(Statement stmt) {
        TemplateInstantiationExpression[] result;
        if (stmt is null) return result;

        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements)
                result ~= findTemplateCallsInStatement(s);
        } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
            result ~= findTemplateCallsInExpression(exprStmt.expression);
        } else if (auto returnStmt = cast(ReturnStatement)stmt) {
            if (returnStmt.value)
                result ~= findTemplateCallsInExpression(returnStmt.value);
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            result ~= findTemplateCallsInExpression(ifStmt.condition);
            result ~= findTemplateCallsInStatement(ifStmt.thenStatement);
            if (ifStmt.elseStatement)
                result ~= findTemplateCallsInStatement(ifStmt.elseStatement);
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            result ~= findTemplateCallsInExpression(whileStmt.condition);
            result ~= findTemplateCallsInStatement(whileStmt.body_);
        } else if (auto forStmt = cast(ForStatement)stmt) {
            if (forStmt.init)
                result ~= findTemplateCallsInStatement(forStmt.init);
            if (forStmt.condition)
                result ~= findTemplateCallsInExpression(forStmt.condition);
            if (forStmt.update)
                result ~= findTemplateCallsInExpression(forStmt.update);
            result ~= findTemplateCallsInStatement(forStmt.body_);
        } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
            if (varDecl.initializer)
                result ~= findTemplateCallsInExpression(varDecl.initializer);
        }
        return result;
    }

    /// Find all TemplateInstantiationExpressions in an expression (recursive).
    private TemplateInstantiationExpression[] findTemplateCallsInExpression(Expression expr) {
        TemplateInstantiationExpression[] result;
        if (expr is null) return result;

        if (auto tmpl = cast(TemplateInstantiationExpression)expr) {
            result ~= tmpl;
            foreach (arg; tmpl.callArguments)
                result ~= findTemplateCallsInExpression(arg);
        } else if (auto binary = cast(BinaryExpression)expr) {
            result ~= findTemplateCallsInExpression(binary.left);
            result ~= findTemplateCallsInExpression(binary.right);
            if (binary.loweredCall)
                result ~= findTemplateCallsInExpression(binary.loweredCall);
        } else if (auto unary = cast(UnaryExpression)expr) {
            result ~= findTemplateCallsInExpression(unary.operand);
            if (unary.loweredCall)
                result ~= findTemplateCallsInExpression(unary.loweredCall);
        } else if (auto call = cast(CallExpression)expr) {
            result ~= findTemplateCallsInExpression(call.function_);
            foreach (arg; call.arguments)
                result ~= findTemplateCallsInExpression(arg);
        } else if (auto assign = cast(AssignmentExpression)expr) {
            result ~= findTemplateCallsInExpression(assign.left);
            result ~= findTemplateCallsInExpression(assign.right);
            if (assign.loweredCall)
                result ~= findTemplateCallsInExpression(assign.loweredCall);
        }
        return result;
    }

    /// Scan statements for variable declarations with struct types and add to structDeps.
    /// This catches struct template instantiations used in type position (e.g. `Sized!(3) s;`)
    /// which don't appear as TemplateInstantiationExpressions.
    private void collectStructDepsFromStatements(Statement stmt) {
        if (stmt is null) return;

        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements)
                collectStructDepsFromStatements(s);
        } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
            if (auto ut = cast(UserType)varDecl.type) {
                if (auto sd = ut.asStruct()) {
                    if (sd.name !in neededStructs) {
                        neededStructs[sd.name] = true;
                        structDeps ~= sd;
                    }
                }
            }
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            collectStructDepsFromStatements(ifStmt.thenStatement);
            collectStructDepsFromStatements(ifStmt.elseStatement);
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            collectStructDepsFromStatements(whileStmt.body_);
        } else if (auto forStmt = cast(ForStatement)stmt) {
            collectStructDepsFromStatements(forStmt.init);
            collectStructDepsFromStatements(forStmt.body_);
        }
    }

    /**
     * Collect all virtual methods from class-typed variables/parameters in a function.
     * This ensures overridden methods are compiled for virtual dispatch.
     */
    private void collectClassMethodDeps(FunctionDecl func, ref FunctionDecl[] result) {
        // Collect from parameters
        foreach (param; func.parameters) {
            if (auto cd = param.type.asClass()) {
                collectAllClassMethods(cd, result);
            }
        }
        // Collect from local variable declarations in the body
        collectClassMethodDepsFromStatements(func.body_, result);
    }

    private void collectClassMethodDepsFromStatements(Statement stmt, ref FunctionDecl[] result) {
        if (stmt is null) return;
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements)
                collectClassMethodDepsFromStatements(s, result);
        } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
            if (auto ut = cast(UserType)varDecl.type) {
                if (auto cd = ut.asClass()) {
                    collectAllClassMethods(cd, result);
                }
            }
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            collectClassMethodDepsFromStatements(ifStmt.thenStatement, result);
            collectClassMethodDepsFromStatements(ifStmt.elseStatement, result);
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            collectClassMethodDepsFromStatements(whileStmt.body_, result);
        } else if (auto forStmt = cast(ForStatement)stmt) {
            collectClassMethodDepsFromStatements(forStmt.init, result);
            collectClassMethodDepsFromStatements(forStmt.body_, result);
        }
    }

    /// Add all methods from a class (and its bases) as dependencies.
    private void collectAllClassMethods(ClassDecl classDecl, ref FunctionDecl[] result) {
        ClassDecl current = classDecl;
        while (current !is null) {
            foreach (member; current.members) {
                if (auto fd = cast(FunctionDecl)member) {
                    if (fd.isMethod && fd.body_ !is null) {
                        collectDependencies(fd, result);
                    }
                }
            }
            current = current.baseClassDecl;
        }
    }

    /**
     * Resolve a CallExpression to its FunctionDecl, if it's a D function.
     * Returns null for builtins, intrinsics, or unresolved calls.
     */
    private FunctionDecl resolveFunction(CallExpression call) {
        // Handle direct function calls: foo()
        if (auto ident = cast(IdentifierExpression)call.function_) {
            string funcName = ident.name;

            // Skip builtins/intrinsics
            if (isBuiltin(funcName)) {
                return null;
            }

            // Look up in declarations — prefer definition with body over forward declaration
            FunctionDecl forwardDecl;
            foreach (decl; allDeclarations) {
                if (auto funcDecl = cast(FunctionDecl)decl) {
                    if (funcDecl.name == funcName) {
                        if (funcDecl.body_ !is null)
                            return funcDecl;
                        if (forwardDecl is null)
                            forwardDecl = funcDecl;
                    }
                }
            }
            if (forwardDecl !is null)
                return forwardDecl;

            // Also check symbol table
            auto symbol = symbolTable.lookupSymbol(funcName);
            if (symbol && symbol.kind == SymbolKind.Function) {
                if (auto funcDecl = cast(FunctionDecl)symbol.declaration) {
                    return funcDecl;
                }
            }
        }

        // Handle method calls: obj.method()
        if (auto member = cast(MemberExpression)call.function_) {
            string methodName = member.memberName;

            // Search struct and class declarations for a matching method
            foreach (decl; allDeclarations) {
                if (auto sd = cast(StructDecl)decl) {
                    foreach (m; sd.members) {
                        if (auto fd = cast(FunctionDecl)m) {
                            if (fd.name == methodName && fd.isMethod) {
                                return fd;
                            }
                        }
                    }
                }
                if (auto cd = cast(ClassDecl)decl) {
                    foreach (m; cd.members) {
                        if (auto fd = cast(FunctionDecl)m) {
                            if (fd.name == methodName && fd.isMethod) {
                                return fd;
                            }
                        }
                    }
                    // Also search base classes
                    auto base = cd.baseClassDecl;
                    while (base !is null) {
                        foreach (m; base.members) {
                            if (auto fd = cast(FunctionDecl)m) {
                                if (fd.name == methodName && fd.isMethod) {
                                    return fd;
                                }
                            }
                        }
                        base = base.baseClassDecl;
                    }
                }
            }

            // Also search struct template instantiations (may not be in allDeclarations yet)
            foreach (sd; structDeps) {
                foreach (m; sd.members) {
                    if (auto fd = cast(FunctionDecl)m) {
                        if (fd.name == methodName && fd.isMethod) {
                            return fd;
                        }
                    }
                }
            }
        }

        return null;
    }

    /**
     * Check if a function name is a builtin/intrinsic.
     */
    private bool isBuiltin(string name) {
        // Known builtins that don't need dependency tracking
        static immutable builtins = [
            "__writeln",
            "__ctfe_runtime",
            "__text",
            "import",
        ];

        foreach (b; builtins) {
            if (name == b) return true;
        }

        // Names starting with __ are generally intrinsics
        if (name.length >= 2 && name[0..2] == "__") {
            return true;
        }

        return false;
    }
}

// Unit tests
unittest {
    import std.stdio;

    // Test would require setting up AST nodes, which is complex
    // For now, rely on integration tests
    writeln("DependencyAnalyzer module loaded");
}
