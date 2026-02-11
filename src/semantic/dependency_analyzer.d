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

    /// Compute a unique key for a function (mangled name for methods).
    private static string funcKey(FunctionDecl func) {
        if (func.isMethod && func.parent !is null) {
            if (auto sd = cast(StructDecl)func.parent)
                return sd.name ~ "_" ~ func.name;
            if (auto cd = cast(ClassDecl)func.parent)
                return cd.name ~ "_" ~ func.name;
        }
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

        // Find all calls in this function's body
        auto calls = findCallsInStatement(func.body_);

        foreach (call; calls) {
            // Try to resolve the call to a FunctionDecl
            auto calledFunc = resolveFunction(call);
            if (calledFunc !is null) {
                collectDependencies(calledFunc, result);
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
        } else if (auto unary = cast(UnaryExpression)expr) {
            calls ~= findCallsInExpression(unary.operand);
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
        }
        // IdentifierExpression, LiteralExpression - no calls inside

        return calls;
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

            // Look up in declarations
            foreach (decl; allDeclarations) {
                if (auto funcDecl = cast(FunctionDecl)decl) {
                    if (funcDecl.name == funcName) {
                        return funcDecl;
                    }
                }
            }

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

            // Search struct declarations for a matching method
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
