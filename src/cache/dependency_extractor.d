/**
 * Dependency Extractor for Incremental Compilation Cache
 * 
 * Extracts ALL referenced symbols from a module member:
 * - Function calls (transitive)
 * - Type references (structs, enums)
 * - Global variable references
 * 
 * Returns symbol names for cache invalidation tracking.
 */
module cache.dependency_extractor;

import ast.nodes;
import ast.statements;
import ast.expressions;

import std.algorithm;
import std.array;

/**
 * Result of dependency extraction
 */
struct DependencyInfo {
    string[] functions;   // Called function names
    string[] types;       // Referenced type names (structs, enums)
    string[] globals;     // Referenced global variable names
    
    /// All dependencies as a single sorted, unique array
    string[] all() const {
        auto combined = (functions ~ types ~ globals).dup;
        combined = combined.sort.uniq.array;
        return combined;
    }
}

/**
 * Extract dependencies from a function declaration.
 */
DependencyInfo extractDependencies(FunctionDecl func, Declaration[] allDeclarations) {
    auto extractor = new DependencyExtractor(allDeclarations);
    return extractor.extract(func);
}

/**
 * Extract dependencies from a struct declaration.
 */
DependencyInfo extractDependencies(StructDecl struct_, Declaration[] allDeclarations) {
    auto extractor = new DependencyExtractor(allDeclarations);
    return extractor.extract(struct_);
}

private class DependencyExtractor {
    private Declaration[] allDeclarations;
    private bool[string] visitedFunctions;
    
    // Collected dependencies
    private bool[string] functions;
    private bool[string] types;
    private bool[string] globals;
    
    this(Declaration[] declarations) {
        this.allDeclarations = declarations;
    }
    
    DependencyInfo extract(FunctionDecl func) {
        // Include static if condition dependencies
        foreach (dep; func.staticIfDependencies) {
            functions[dep] = true;  // Treat as function deps (covers manifest constants)
        }
        
        // Extract from return type
        extractFromType(func.returnType);
        
        // Extract from parameters
        foreach (param; func.parameters) {
            extractFromType(param.type);
        }
        
        // Extract from body (includes function calls)
        if (func.body_) {
            extractFromStatement(func.body_);
        }
        
        // Collect transitive function dependencies
        collectTransitiveFunctionDeps();
        
        return buildResult();
    }
    
    DependencyInfo extract(StructDecl struct_) {
        // Include static if condition dependencies
        foreach (dep; struct_.staticIfDependencies) {
            functions[dep] = true;  // Treat as function deps (covers manifest constants)
        }
        
        // Extract from field types
        foreach (field; struct_.fields) {
            extractFromType(field.type);
        }
        
        // Extract from methods (which are FunctionDecl members)
        foreach (member; struct_.members) {
            if (auto method = cast(FunctionDecl)member) {
                extractFromType(method.returnType);
                foreach (param; method.parameters) {
                    extractFromType(param.type);
                }
                if (method.body_) {
                    extractFromStatement(method.body_);
                }
            }
        }
        
        collectTransitiveFunctionDeps();
        return buildResult();
    }
    
    private DependencyInfo buildResult() {
        DependencyInfo info;
        info.functions = functions.keys.sort.array;
        info.types = types.keys.sort.array;
        info.globals = globals.keys.sort.array;
        return info;
    }
    
    private void collectTransitiveFunctionDeps() {
        // For each directly called function, find its dependencies too
        string[] toProcess = functions.keys.dup;
        
        while (toProcess.length > 0) {
            string funcName = toProcess[$ - 1];
            toProcess = toProcess[0 .. $ - 1];
            
            if (funcName in visitedFunctions) continue;
            visitedFunctions[funcName] = true;
            
            // Find the function declaration
            auto funcDecl = findFunction(funcName);
            if (funcDecl is null) continue;
            
            // Extract its dependencies
            if (funcDecl.body_) {
                auto calls = findCallsInStatement(funcDecl.body_);
                foreach (call; calls) {
                    auto name = getCallName(call);
                    if (name.length > 0 && !isBuiltin(name)) {
                        if (name !in functions) {
                            functions[name] = true;
                            toProcess ~= name;
                        }
                    }
                }
            }
            
            // Also get type refs from the function
            extractFromType(funcDecl.returnType);
            foreach (param; funcDecl.parameters) {
                extractFromType(param.type);
            }
        }
    }
    
    private void extractFromType(Type type) {
        if (type is null) return;
        
        if (auto userType = cast(UserType)type) {
            // User-defined type (struct, enum, etc.)
            types[userType.name] = true;
        } else if (auto array = cast(ArrayType)type) {
            extractFromType(array.elementType);
        } else if (auto pointer = cast(PointerType)type) {
            extractFromType(pointer.pointeeType);
        }
        // BasicType doesn't reference other symbols
    }
    
    private void extractFromStatement(Statement stmt) {
        if (stmt is null) return;
        
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                extractFromStatement(s);
            }
        } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
            extractFromExpression(exprStmt.expression);
        } else if (auto returnStmt = cast(ReturnStatement)stmt) {
            if (returnStmt.value) {
                extractFromExpression(returnStmt.value);
            }
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            extractFromExpression(ifStmt.condition);
            extractFromStatement(ifStmt.thenStatement);
            if (ifStmt.elseStatement) {
                extractFromStatement(ifStmt.elseStatement);
            }
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            extractFromExpression(whileStmt.condition);
            extractFromStatement(whileStmt.body_);
        } else if (auto forStmt = cast(ForStatement)stmt) {
            if (forStmt.init) extractFromStatement(forStmt.init);
            if (forStmt.condition) extractFromExpression(forStmt.condition);
            if (forStmt.update) extractFromExpression(forStmt.update);
            extractFromStatement(forStmt.body_);
        } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
            extractFromType(varDecl.type);
            if (varDecl.initializer) {
                extractFromExpression(varDecl.initializer);
            }
        }
    }
    
    private void extractFromExpression(Expression expr) {
        if (expr is null) return;
        
        if (auto call = cast(CallExpression)expr) {
            auto name = getCallName(call);
            if (name.length > 0 && !isBuiltin(name)) {
                functions[name] = true;
            }
            foreach (arg; call.arguments) {
                extractFromExpression(arg);
            }
        } else if (auto ident = cast(IdentifierExpression)expr) {
            // Could be a global variable
            // For now we don't distinguish - would need symbol table
            // TODO: track globals separately when we have symbol info
        } else if (auto binary = cast(BinaryExpression)expr) {
            extractFromExpression(binary.left);
            extractFromExpression(binary.right);
        } else if (auto unary = cast(UnaryExpression)expr) {
            extractFromExpression(unary.operand);
        } else if (auto index = cast(IndexExpression)expr) {
            extractFromExpression(index.array);
            extractFromExpression(index.index);
        } else if (auto member = cast(MemberExpression)expr) {
            extractFromExpression(member.object);
        } else if (auto arrayLit = cast(ArrayLiteralExpression)expr) {
            foreach (elem; arrayLit.elements) {
                extractFromExpression(elem);
            }
        } else if (auto cast_ = cast(CastExpression)expr) {
            extractFromType(cast_.targetType);
            extractFromExpression(cast_.expression);
        } else if (auto assign = cast(AssignmentExpression)expr) {
            extractFromExpression(assign.left);
            extractFromExpression(assign.right);
        }
        // Note: Struct construction (Point(1,2)) is a CallExpression
        // Type dependency is tracked when we resolve the call target
    }
    
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
            if (returnStmt.value) calls ~= findCallsInExpression(returnStmt.value);
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            calls ~= findCallsInExpression(ifStmt.condition);
            calls ~= findCallsInStatement(ifStmt.thenStatement);
            if (ifStmt.elseStatement) calls ~= findCallsInStatement(ifStmt.elseStatement);
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            calls ~= findCallsInExpression(whileStmt.condition);
            calls ~= findCallsInStatement(whileStmt.body_);
        } else if (auto forStmt = cast(ForStatement)stmt) {
            if (forStmt.init) calls ~= findCallsInStatement(forStmt.init);
            if (forStmt.condition) calls ~= findCallsInExpression(forStmt.condition);
            if (forStmt.update) calls ~= findCallsInExpression(forStmt.update);
            calls ~= findCallsInStatement(forStmt.body_);
        } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
            if (varDecl.initializer) calls ~= findCallsInExpression(varDecl.initializer);
        }
        
        return calls;
    }
    
    private CallExpression[] findCallsInExpression(Expression expr) {
        CallExpression[] calls;
        if (expr is null) return calls;
        
        if (auto call = cast(CallExpression)expr) {
            calls ~= call;
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
        
        return calls;
    }
    
    private string getCallName(CallExpression call) {
        if (auto ident = cast(IdentifierExpression)call.function_) {
            return ident.name;
        }
        // TODO: Handle method calls (member.method)
        return "";
    }
    
    private FunctionDecl findFunction(string name) {
        foreach (decl; allDeclarations) {
            if (auto funcDecl = cast(FunctionDecl)decl) {
                if (funcDecl.name == name) {
                    return funcDecl;
                }
            }
        }
        return null;
    }
    
    private bool isBuiltin(string name) {
        if (name.length >= 2 && name[0..2] == "__") {
            return true;
        }
        static immutable builtins = ["import", "mixin", "assert"];
        return builtins.canFind(name);
    }
    
    private bool isBasicType(string name) {
        static immutable basics = [
            "int", "uint", "long", "ulong",
            "short", "ushort", "byte", "ubyte",
            "float", "double", "real",
            "char", "wchar", "dchar",
            "bool", "void", "string"
        ];
        return basics.canFind(name);
    }
}

// Unit tests
unittest {
    import std.stdio : writeln;
    import ast.nodes : SourceLocation, FunctionDecl, Parameter, BasicType, UserType, StructDecl, StructField;
    import ast.statements : CompoundStatement, ReturnStatement, VariableDeclarationStatement;
    import ast.expressions : CallExpression, IdentifierExpression, BinaryExpression, LiteralExpression;
    
    auto loc = SourceLocation("test.d", 1, 1);
    
    // Test 1: Function with call dependency
    {
        // Create: int foo() { return bar(); }
        auto barCall = new CallExpression(loc, new IdentifierExpression(loc, "bar"), []);
        auto returnStmt = new ReturnStatement(loc, barCall);
        auto body_ = new CompoundStatement(loc, [returnStmt]);
        auto foo = new FunctionDecl(loc, "foo", new BasicType(loc, BasicType.Kind.Int32), [], body_);
        
        auto deps = extractDependencies(foo, []);
        
        assert(deps.functions.canFind("bar"), "Should detect call to bar");
        writeln("✓ Function call dependency detected");
    }
    
    // Test 2: Function with type dependency
    {
        // Create: Point getPoint() { return 0; }
        auto pointType = new UserType(loc, "Point");
        auto returnStmt = new ReturnStatement(loc, LiteralExpression.integer(loc, 0));
        auto body_ = new CompoundStatement(loc, [returnStmt]);
        auto getPoint = new FunctionDecl(loc, "getPoint", pointType, [], body_);
        
        auto deps = extractDependencies(getPoint, []);
        
        assert(deps.types.canFind("Point"), "Should detect Point type in return type");
        writeln("✓ Return type dependency detected");
    }
    
    // Test 3: Function with parameter type dependency
    {
        // Create: void process(Widget w) { }
        auto widgetType = new UserType(loc, "Widget");
        auto param = Parameter(widgetType, "w", null);
        auto body_ = new CompoundStatement(loc, []);
        auto process = new FunctionDecl(loc, "process", new BasicType(loc, BasicType.Kind.Void), [param], body_);
        
        auto deps = extractDependencies(process, []);
        
        assert(deps.types.canFind("Widget"), "Should detect Widget type in parameter");
        writeln("✓ Parameter type dependency detected");
    }
    
    // Test 4: Local variable type dependency
    {
        // Create: void test() { Config c; }
        auto configType = new UserType(loc, "Config");
        auto varDecl = new VariableDeclarationStatement(loc, "c", configType, null);
        auto body_ = new CompoundStatement(loc, [varDecl]);
        auto test = new FunctionDecl(loc, "test", new BasicType(loc, BasicType.Kind.Void), [], body_);
        
        auto deps = extractDependencies(test, []);
        
        assert(deps.types.canFind("Config"), "Should detect Config type in local variable");
        writeln("✓ Local variable type dependency detected");
    }
    
    // Test 5: all() returns unique sorted list
    {
        auto barCall = new CallExpression(loc, new IdentifierExpression(loc, "bar"), []);
        auto bazCall = new CallExpression(loc, new IdentifierExpression(loc, "baz"), []);
        auto barCall2 = new CallExpression(loc, new IdentifierExpression(loc, "bar"), []); // duplicate
        
        auto expr = new BinaryExpression(loc, barCall, BinaryExpression.Operator.Add,
            new BinaryExpression(loc, bazCall, BinaryExpression.Operator.Add, barCall2));
        
        auto returnStmt = new ReturnStatement(loc, expr);
        auto body_ = new CompoundStatement(loc, [returnStmt]);
        auto foo = new FunctionDecl(loc, "foo", new BasicType(loc, BasicType.Kind.Int32), [], body_);
        
        auto deps = extractDependencies(foo, []);
        auto all = deps.all();
        
        assert(all.length == 2, "Should deduplicate: bar appears once");
        assert(all[0] == "bar" && all[1] == "baz", "Should be sorted");
        writeln("✓ Deduplication and sorting works");
    }
    
    writeln("✓ DependencyExtractor all tests passed");
}
