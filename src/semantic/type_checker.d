/**
 * Type Checker for D-to-WASM Compiler
 * 
 * This module implements type checking and type inference for the supported D subset.
 * It validates type compatibility, performs necessary type conversions, and reports type errors.
 */
module semantic.type_checker;

import ast.nodes;
import ast.statements;
import ast.expressions;
import semantic.symbol_table;
import std.string;
import std.array;
import std.algorithm;
import std.conv;
import std.stdio;
import diagnostic.log : log;

/**
 * Type checking error
 */
class TypeError : Exception {
    SourceLocation location;
    
    this(string message, SourceLocation location, string file = __FILE__, size_t line = __LINE__) {
        this.location = location;
        super(format("Type error: %s at %s", message, location.toString()), file, line);
    }
}

/**
 * Type compatibility information
 */
struct TypeCompatibility {
    bool isCompatible;
    bool needsConversion;
    Type targetType;  // The type to convert to if conversion is needed
    
    static TypeCompatibility compatible() {
        return TypeCompatibility(true, false, null);
    }
    
    static TypeCompatibility withConversion(Type targetType) {
        return TypeCompatibility(true, true, targetType);
    }
    
    static TypeCompatibility incompatible() {
        return TypeCompatibility(false, false, null);
    }
}

/**
 * Main type checker class
 */
class TypeChecker {
    private SymbolTable symbolTable;
    private Type currentFunctionReturnType;
    private StructDecl currentStructDecl;  // Non-null when inside a method
    
    // Unique local ID counter - reset per function
    private uint nextLocalId;
    
    // Stack of scope variable lists for RAII unwind tracking
    // Each entry is a list of local IDs declared in that scope
    private uint[][] scopeVarStack;
    
    this(SymbolTable symbolTable) {
        this.symbolTable = symbolTable;
    }
    
    /**
     * Allocate the next unique local ID (for variables/parameters)
     */
    private uint allocateLocalId() {
        return nextLocalId++;
    }
    
    /**
     * Push a new scope onto the variable tracking stack
     */
    private void pushScopeVars() {
        scopeVarStack ~= [];
    }
    
    /**
     * Pop the current scope from the variable tracking stack
     */
    private uint[] popScopeVars() {
        if (scopeVarStack.length == 0) return [];
        auto vars = scopeVarStack[$-1];
        scopeVarStack = scopeVarStack[0..$-1];
        return vars;
    }
    
    /**
     * Add a variable to the current scope's tracking list
     */
    private void trackScopeVar(uint localId) {
        if (scopeVarStack.length > 0) {
            scopeVarStack[$-1] ~= localId;
        }
    }
    
    /**
     * Get the current unwind chain (all scope vars from innermost to outermost)
     */
    private uint[][] getUnwindChain() {
        // Return a copy of the stack (innermost is at index 0)
        uint[][] chain;
        foreach_reverse (scope_; scopeVarStack) {
            chain ~= scope_.dup;
        }
        return chain;
    }
    
    /**
     * Type check a list of declarations
     */
    void checkDeclarations(Declaration[] declarations) {
        foreach (decl; declarations) {
            checkDeclaration(decl);
        }
    }
    
    /**
     * Type check a single declaration
     */
    void checkDeclaration(Declaration decl) {
        if (auto funcDecl = cast(FunctionDecl)decl) {
            checkFunctionDeclaration(funcDecl);
        } else if (auto classDecl = cast(ClassDecl)decl) {
            checkClassDeclaration(classDecl);
        } else if (auto structDecl = cast(StructDecl)decl) {
            checkStructDeclaration(structDecl);
        } else if (auto varDecl = cast(VariableDecl)decl) {
            checkVariableDeclaration(varDecl);
        } else if (auto enumDecl = cast(EnumDecl)decl) {
            checkEnumDeclaration(enumDecl);
        }
    }
    
    /**
     * Type check function declaration
     */
    void checkFunctionDeclaration(FunctionDecl decl) {
        // Skip if already type-checked (CTFE may have triggered early check)
        if (decl.isTypeChecked) {
            return;
        }
        
        log(3, "Type checking function: ", decl.name);
        
        // Skip CTFE-only functions (functions that return string type)
        // These are only used at compile time for mixin expansion
        if (auto userType = cast(UserType)decl.returnType) {
            if (userType.name == "string") {
                log(3, "Skipping type check for CTFE-only function: ", decl.name);
                return;
            }
        }
        
        // Enter function scope
        if (!symbolTable) { log(1, "Error: symbolTable is null!"); return; }
        symbolTable.enterScope("function:" ~ decl.name);
        scope(exit) symbolTable.exitScope();
        
        // Reset unique local ID counter and scope tracking for this function
        nextLocalId = 0;
        scopeVarStack = [];
        pushScopeVars();  // Function scope
        scope(exit) popScopeVars();
        
        // Set current return type for return statement checking
        Type oldReturnType = currentFunctionReturnType;
        currentFunctionReturnType = decl.returnType;
        scope(exit) currentFunctionReturnType = oldReturnType;
        
        // Set current struct if this is a method
        StructDecl oldStructDecl = currentStructDecl;
        if (decl.isMethod) {
            currentStructDecl = cast(StructDecl)decl.parent;
        }
        scope(exit) currentStructDecl = oldStructDecl;
        
        // Add parameters to scope and assign unique IDs
        log(3, "Checking parameters for ", decl.name);
        foreach (i, ref param; decl.parameters) {
            log(3, "  Parameter: ", param.name);
            
            // Assign unique local ID
            param.uniqueLocalId = allocateLocalId();
            
            // Check if parameter type is null (from parsing issues)
            if (!param.type) {
                throw new TypeError(
                    format("Parameter '%s' has unknown type", param.name),
                    decl.location
                );
            }
            
            auto symbol = new Symbol(
                param.name,
                SymbolKind.Parameter,
                param.type,
                null,
                decl.location,
                false
            );
            symbol.uniqueLocalId = param.uniqueLocalId;
            symbolTable.addSymbol(symbol);
            
            // Type check default value if present
            if (param.defaultValue) {
                Type defaultType = checkExpression(param.defaultValue);
                auto compat = checkTypeCompatibility(defaultType, param.type);
                if (!compat.isCompatible) {
                    throw new TypeError(
                        format("Parameter default value type '%s' is not compatible with parameter type '%s'",
                               defaultType.toString(), param.type.toString()),
                        param.defaultValue.location
                    );
                }
            }
        }
        
        // Type check function body
        if (decl.body_) {
            log(3, "Checking body for ", decl.name);
            checkStatement(decl.body_);
            
            // Check that non-void functions return on all paths
            // Skip this check if the body is empty (likely due to parse errors)
            if (!isVoidType(decl.returnType)) {
                if (!isEmptyBody(decl.body_) && !allPathsReturn(decl.body_)) {
                    throw new TypeError(
                        format("Function '%s' does not return a value on all control flow paths", decl.name),
                        decl.location
                    );
                }
            }
        }
        
        // Mark as type-checked to avoid redundant passes
        decl.isTypeChecked = true;
    }
    
    /**
     * Check if a function body is effectively empty (no statements).
     * This can happen due to parse errors dropping statements.
     */
    private bool isEmptyBody(Statement stmt) {
        if (!stmt) return true;
        if (auto compound = cast(CompoundStatement)stmt) {
            return compound.statements.length == 0;
        }
        return false;
    }
    
    /**
     * Check if all control flow paths in a statement return a value.
     * Returns true if the statement always returns (or terminates).
     */
    private bool allPathsReturn(Statement stmt) {
        if (!stmt) return false;
        
        if (auto compound = cast(CompoundStatement)stmt) {
            // A compound statement returns if any of its statements always returns
            foreach (s; compound.statements) {
                if (allPathsReturn(s)) return true;
            }
            return false;
        }
        
        if (auto returnStmt = cast(ReturnStatement)stmt) {
            // A return statement with or without a value always terminates
            return true;
        }
        
        if (auto ifStmt = cast(IfStatement)stmt) {
            // An if statement returns only if BOTH branches exist and BOTH return
            if (ifStmt.elseStatement is null) {
                return false;  // No else branch, so the if might not return
            }
            return allPathsReturn(ifStmt.thenStatement) && allPathsReturn(ifStmt.elseStatement);
        }
        
        if (auto whileStmt = cast(WhileStatement)stmt) {
            // While loops might not execute at all, so they don't guarantee return
            return false;
        }
        
        if (auto forStmt = cast(ForStatement)stmt) {
            // For loops might not execute at all, so they don't guarantee return
            return false;
        }
        
        // Other statements (expression, variable declaration) don't return
        return false;
    }
    
    /**
     * Type check variable declaration
     */
    void checkVariableDeclaration(VariableDecl decl) {
        // Type check initializer if present
        if (decl.initializer) {
            Type initType = checkExpression(decl.initializer);
            auto compat = checkTypeCompatibility(initType, decl.type);
            if (!compat.isCompatible) {
                throw new TypeError(
                    format("Initializer type '%s' is not compatible with variable type '%s'",
                           initType.toString(), decl.type.toString()),
                    decl.initializer.location
                );
            }
        }
    }
    
    /**
     * Type check class declaration (basic implementation)
     */
    void checkClassDeclaration(ClassDecl decl) {
        symbolTable.enterScope("class:" ~ decl.name);
        scope(exit) symbolTable.exitScope();
        
        // TODO: Type check class members
        foreach (member; decl.members) {
            checkDeclaration(member);
        }
    }
    
    /**
     * Type check struct declaration
     */
    void checkStructDeclaration(StructDecl decl) {
        symbolTable.enterScope("struct:" ~ decl.name);
        scope(exit) symbolTable.exitScope();
        
        foreach (member; decl.members) {
            checkDeclaration(member);
        }
    }
    
    /**
     * Type check enum declaration
     */
    void checkEnumDeclaration(EnumDecl decl) {
        // TODO: Check enum member values are compatible with base type
    }
    
    /**
     * Type check a statement
     */
    void checkStatement(Statement stmt) {
        if (!stmt) {
            log(2, "Warning: visiting null statement in TypeChecker");
            return;
        }
        // writeln("Checking statement type: ", typeid(stmt).name);
        
        if (auto compound = cast(CompoundStatement)stmt) {
            symbolTable.enterScope("block");
            pushScopeVars();
            scope(exit) {
                compound.destructOnExit = popScopeVars();
                symbolTable.exitScope();
            }
            
            foreach (s; compound.statements) {
                checkStatement(s);
            }
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            // Check condition must be bool (strict D semantics)
            Type condType = checkExpression(ifStmt.condition);
            if (!isBooleanConvertible(condType)) {
                throw new TypeError(
                    format("If condition must be bool, got '%s'", condType.toString()),
                    ifStmt.condition.location
                );
            }
            
            checkStatement(ifStmt.thenStatement);
            if (ifStmt.elseStatement) {
                checkStatement(ifStmt.elseStatement);
            }
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            Type condType = checkExpression(whileStmt.condition);
            if (!isBooleanConvertible(condType)) {
                throw new TypeError(
                    format("While condition must be bool, got '%s'", condType.toString()),
                    whileStmt.condition.location
                );
            }
            
            checkStatement(whileStmt.body_);
        } else if (auto forStmt = cast(ForStatement)stmt) {
            symbolTable.enterScope("for");
            scope(exit) symbolTable.exitScope();
            
            if (forStmt.init) {
                checkStatement(forStmt.init);
            }
            if (forStmt.condition) {
                Type condType = checkExpression(forStmt.condition);
                if (!isBooleanConvertible(condType)) {
                    throw new TypeError(
                        format("For condition must be bool, got '%s'", condType.toString()),
                        forStmt.condition.location
                    );
                }
            }
            if (forStmt.update) {
                checkExpression(forStmt.update);
            }
            
            checkStatement(forStmt.body_);
        } else if (auto returnStmt = cast(ReturnStatement)stmt) {
            // Capture unwind chain for RAII destruction
            returnStmt.unwindChain = getUnwindChain();
            
            if (returnStmt.value) {
                Type returnType = checkExpression(returnStmt.value);
                if (!currentFunctionReturnType) {
                    throw new TypeError("Return statement outside of any function", returnStmt.location);
                }
                auto compat = checkTypeCompatibility(returnType, currentFunctionReturnType);
                if (!compat.isCompatible) {
                    throw new TypeError(
                        format("Return type '%s' is not compatible with function return type '%s'",
                               returnType.toString(), currentFunctionReturnType.toString()),
                        returnStmt.value.location
                    );
                }
            } else {
                // Void return
                if (!isVoidType(currentFunctionReturnType)) {
                    throw new TypeError(
                        format("Cannot return void from function with return type '%s'",
                               currentFunctionReturnType.toString()),
                        returnStmt.location
                    );
                }
            }
        } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
            checkExpression(exprStmt.expression);
        } else if (auto varDeclStmt = cast(VariableDeclarationStatement)stmt) {
            // Assign unique local ID
            varDeclStmt.uniqueLocalId = allocateLocalId();
            
            // Track for RAII unwind
            trackScopeVar(varDeclStmt.uniqueLocalId);
            
            // Type check initializer if present
            if (varDeclStmt.initializer) {
                Type initType = checkExpression(varDeclStmt.initializer);
                auto compat = checkTypeCompatibility(initType, varDeclStmt.type);
                if (!compat.isCompatible) {
                    throw new TypeError(
                        format("Initializer type '%s' is not compatible with variable type '%s'",
                               initType.toString(), varDeclStmt.type.toString()),
                        varDeclStmt.initializer.location
                    );
                }
            }
            // Add the variable to the symbol table
            auto symbol = new Symbol(varDeclStmt.name, SymbolKind.Variable, varDeclStmt.type, 
                                     null, varDeclStmt.location, false);
            symbol.uniqueLocalId = varDeclStmt.uniqueLocalId;
            symbolTable.addSymbol(symbol);
        }
    }
    
    /**
     * Type check an expression and return its type
     */
    Type checkExpression(Expression expr) {
        if (!expr) {
            log(2, "Error: visiting null expression in TypeChecker");
            return new BasicType(SourceLocation(), BasicType.Kind.Void);
        }
        // writeln("Checking expression type: ", typeid(expr).name);
        
        if (auto binary = cast(BinaryExpression)expr) {
            return checkBinaryExpression(binary);
        } else if (auto unary = cast(UnaryExpression)expr) {
            return checkUnaryExpression(unary);
        } else if (auto call = cast(CallExpression)expr) {
            return checkCallExpression(call);
        } else if (auto index = cast(IndexExpression)expr) {
            return checkIndexExpression(index);
        } else if (auto member = cast(MemberExpression)expr) {
            return checkMemberExpression(member);
        } else if (auto ident = cast(IdentifierExpression)expr) {
            return checkIdentifierExpression(ident);
        } else if (auto literal = cast(LiteralExpression)expr) {
            return inferLiteralType(literal);
        } else if (auto cast_ = cast(CastExpression)expr) {
            return checkCastExpression(cast_);
        } else if (auto assign = cast(AssignmentExpression)expr) {
            return checkAssignmentExpression(assign);
        } else if (auto arrayLit = cast(ArrayLiteralExpression)expr) {
            return checkArrayLiteralExpression(arrayLit);
        } else if (auto slice = cast(SliceExpression)expr) {
            return checkSliceExpression(slice);
        } else if (auto import_ = cast(ImportExpression)expr) {
            return checkImportExpression(import_);
        }
        
        throw new TypeError("Unknown expression type", expr.location);
    }
    
    /**
     * Type check binary expression
     */
    Type checkBinaryExpression(BinaryExpression expr) {
        Type leftType = checkExpression(expr.left);
        Type rightType = checkExpression(expr.right);
        
        // Arithmetic operators
        if (expr.operator >= BinaryExpression.Operator.Add && 
            expr.operator <= BinaryExpression.Operator.Modulo) {
            
            if (!isArithmeticType(leftType) || !isArithmeticType(rightType)) {
                throw new TypeError(
                    format("Arithmetic operator requires numeric types, got '%s' and '%s'",
                           leftType.toString(), rightType.toString()),
                    expr.location
                );
            }
            
            return promoteArithmeticTypes(leftType, rightType, expr.location);
        }
        
        // Comparison operators
        if (expr.operator >= BinaryExpression.Operator.Equal && 
            expr.operator <= BinaryExpression.Operator.GreaterEqual) {
            
            // Check for null types first
            if (!leftType) {
                throw new TypeError(
                    format("Left operand has unknown type in binary expression (operator: %s)", expr.operator),
                    expr.location
                );
            }
            if (!rightType) {
                throw new TypeError(
                    format("Right operand has unknown type in binary expression (operator: %s)", expr.operator),
                    expr.location
                );
            }
            
            auto compat = checkTypeCompatibility(leftType, rightType);
            if (!compat.isCompatible && !checkTypeCompatibility(rightType, leftType).isCompatible) {
                throw new TypeError(
                    format("Cannot compare types '%s' and '%s'",
                           leftType.toString(), rightType.toString()),
                    expr.location
                );
            }
            
            return new BasicType(expr.location, BasicType.Kind.Bool);
        }
        
        // Logical operators
        if (expr.operator == BinaryExpression.Operator.LogicalAnd || 
            expr.operator == BinaryExpression.Operator.LogicalOr) {
            
            if (!isBooleanConvertible(leftType) || !isBooleanConvertible(rightType)) {
                throw new TypeError(
                    format("Logical operator requires boolean-convertible types, got '%s' and '%s'",
                           leftType.toString(), rightType.toString()),
                    expr.location
                );
            }
            
            return new BasicType(expr.location, BasicType.Kind.Bool);
        }
        
        // Bitwise operators (and, or, xor, shift)
        if (expr.operator == BinaryExpression.Operator.BitwiseAnd ||
            expr.operator == BinaryExpression.Operator.BitwiseOr ||
            expr.operator == BinaryExpression.Operator.BitwiseXor ||
            expr.operator == BinaryExpression.Operator.ShiftLeft ||
            expr.operator == BinaryExpression.Operator.ShiftRight ||
            expr.operator == BinaryExpression.Operator.UnsignedShiftRight) {
            
            if (!isIntegerType(cast(BasicType)leftType) || !isIntegerType(cast(BasicType)rightType)) {
                throw new TypeError(
                    format("Bitwise operator requires integer types, got '%s' and '%s'",
                           leftType.toString(), rightType.toString()),
                    expr.location
                );
            }
            
            return leftType;  // Result is same type as left operand
        }
        
        throw new TypeError(
            format("Unsupported binary operator"),
            expr.location
        );
    }
    
    /**
     * Type check identifier expression
     */
    Type checkIdentifierExpression(IdentifierExpression expr) {
        // Handle 'this' keyword inside methods
        if (expr.name == "this") {
            if (!currentStructDecl) {
                throw new TypeError("'this' can only be used inside a method", expr.location);
            }
            // 'this' has the type of the enclosing struct
            auto thisType = new UserType(expr.location, currentStructDecl.name);
            thisType.declaration = currentStructDecl;
            return thisType;
        }
        
        Symbol symbol = symbolTable.lookupSymbol(expr.name);
        if (!symbol) {
            // Inside a method, check if it's a field of the current struct (implicit this)
            if (currentStructDecl) {
                auto field = currentStructDecl.getField(expr.name);
                if (field) {
                    return field.type;
                }
            }
            throw new TypeError(
                format("Undefined identifier '%s'", expr.name),
                expr.location
            );
        }
        
        // Store the resolved uniqueLocalId for codegen
        if (symbol.kind == SymbolKind.Variable || symbol.kind == SymbolKind.Parameter) {
            expr.resolvedLocalId = symbol.uniqueLocalId;
        }
        
        return symbol.type;
    }
    
    /**
     * Type check call expression
     */
    /**
     * Type check a __ctfe_runtime magic module call.
     */
    private Type checkCTFERuntimeCall(string funcName, Expression[] arguments, SourceLocation loc) {
        auto intType = new BasicType(loc, BasicType.Kind.Int32);
        auto voidType = new BasicType(loc, BasicType.Kind.Void);
        
        switch (funcName) {
            case "alloc":
                if (arguments.length != 1) {
                    throw new TypeError("__ctfe_runtime.alloc requires 1 argument", loc);
                }
                Type argType = checkExpression(arguments[0]);
                if (!isNumericType(argType)) {
                    throw new TypeError(
                        format("__ctfe_runtime.alloc requires int argument, got '%s'",
                               argType.toString()), loc);
                }
                return intType;  // alloc returns int (pointer)
                
            case "push":
            case "pop":
                if (arguments.length != 0) {
                    throw new TypeError(
                        format("__ctfe_runtime.%s takes no arguments", funcName), loc);
                }
                return voidType;
                
            case "remaining":
                if (arguments.length != 0) {
                    throw new TypeError("__ctfe_runtime.remaining takes no arguments", loc);
                }
                return intType;
                
            default:
                throw new TypeError(
                    format("Unknown __ctfe_runtime function: %s", funcName), loc);
        }
    }
    
    Type checkCallExpression(CallExpression expr) {
        // Handle __ctfe_runtime magic module calls
        if (auto memberExpr = cast(MemberExpression)expr.function_) {
            if (auto objIdent = cast(IdentifierExpression)memberExpr.object) {
                if (objIdent.name == "__ctfe_runtime") {
                    return checkCTFERuntimeCall(memberExpr.memberName, expr.arguments, expr.location);
                }
            }
        }
        
        // Check if this is a struct construction (TypeName(args...))
        if (auto identExpr = cast(IdentifierExpression)expr.function_) {
            auto symbol = symbolTable.lookupSymbol(identExpr.name);
            if (symbol && symbol.kind == SymbolKind.Type) {
                if (auto userType = cast(UserType)symbol.type) {
                    if (auto structDecl = cast(StructDecl)userType.declaration) {
                        // This is struct construction
                        return checkStructConstruction(structDecl, userType, expr.arguments, expr.location);
                    }
                }
            }
        }
        
        // Handle struct method calls (obj.method()) or UFCS (obj.func() -> func(obj))
        if (auto memberExpr = cast(MemberExpression)expr.function_) {
            Type objectType = checkExpression(memberExpr.object);
            bool foundMethod = false;
            
            if (auto userType = cast(UserType)objectType) {
                // Resolve the UserType's declaration if not already linked
                if (!userType.declaration) {
                    auto typeSymbol = symbolTable.lookupSymbol(userType.name);
                    if (typeSymbol && typeSymbol.kind == SymbolKind.Type) {
                        userType.declaration = typeSymbol.declaration;
                    }
                }
                
                if (auto structDecl = cast(StructDecl)userType.declaration) {
                    // Look for a method with this name
                    auto method = getStructMethod(structDecl, memberExpr.memberName);
                    if (method) {
                        foundMethod = true;
                        // Check argument types (method has no explicit 'this' parameter)
                        if (expr.arguments.length != method.parameters.length) {
                            throw new TypeError(
                                format("Method '%s' expects %d arguments, got %d",
                                       memberExpr.memberName, method.parameters.length, expr.arguments.length),
                                expr.location
                            );
                        }
                        
                        for (size_t i = 0; i < expr.arguments.length; i++) {
                            Type argType = checkExpression(expr.arguments[i]);
                            Type paramType = method.parameters[i].type;
                            
                            auto compat = checkTypeCompatibility(argType, paramType);
                            if (!compat.isCompatible) {
                                throw new TypeError(
                                    format("Argument %d: expected type '%s', got '%s'",
                                           i + 1, paramType.toString(), argType.toString()),
                                    expr.arguments[i].location
                                );
                            }
                        }
                        
                        return method.returnType;
                    }
                }
            }
            
            // Check for built-in methods on array types
            if (!foundMethod) {
                if (auto arrayType = cast(ArrayType)objectType) {
                    auto builtinMethod = symbolTable.lookupBuiltinMethod("array", memberExpr.memberName);
                    if (builtinMethod) {
                        foundMethod = true;
                        
                        // Check argument count
                        if (expr.arguments.length != builtinMethod.parameters.length) {
                            throw new TypeError(
                                format("Method '%s' expects %d arguments, got %d",
                                       memberExpr.memberName, builtinMethod.parameters.length, expr.arguments.length),
                                expr.location
                            );
                        }
                        
                        // Check argument types
                        for (size_t i = 0; i < expr.arguments.length; i++) {
                            Type argType = checkExpression(expr.arguments[i]);
                            Type paramType = builtinMethod.parameters[i].type;
                            
                            auto compat = checkTypeCompatibility(argType, paramType);
                            if (!compat.isCompatible) {
                                throw new TypeError(
                                    format("Argument %d: expected type '%s', got '%s'",
                                           i + 1, paramType.toString(), argType.toString()),
                                    expr.arguments[i].location
                                );
                            }
                        }
                        
                        // For opIndex, return the element type, not the generic return type
                        if (memberExpr.memberName == "opIndex") {
                            return arrayType.elementType;
                        }
                        
                        return builtinMethod.returnType;
                    }
                }
            }
            
            // UFCS: If not a method, try to find a free function with that name
            // obj.func(args...) becomes func(obj, args...)
            if (!foundMethod) {
                auto funcSymbol = symbolTable.lookupSymbol(memberExpr.memberName);
                if (funcSymbol && funcSymbol.kind == SymbolKind.Function) {
                    auto funcType = cast(FunctionType)funcSymbol.type;
                    if (funcType) {
                        // UFCS requires at least one parameter (the implicit first arg)
                        if (funcType.parameterTypes.length >= 1) {
                            // Check that object type matches first parameter
                            auto firstParamType = funcType.parameterTypes[0];
                            auto compat = checkTypeCompatibility(objectType, firstParamType);
                            if (compat.isCompatible) {
                                // Check argument count (obj is first arg, rest are explicit)
                                if (expr.arguments.length != funcType.parameterTypes.length - 1) {
                                    throw new TypeError(
                                        format("UFCS call to '%s' expects %d arguments, got %d",
                                               memberExpr.memberName, 
                                               funcType.parameterTypes.length - 1, 
                                               expr.arguments.length),
                                        expr.location
                                    );
                                }
                                
                                // Check remaining argument types
                                for (size_t i = 0; i < expr.arguments.length; i++) {
                                    Type argType = checkExpression(expr.arguments[i]);
                                    Type paramType = funcType.parameterTypes[i + 1];  // +1 to skip first param
                                    
                                    auto argCompat = checkTypeCompatibility(argType, paramType);
                                    if (!argCompat.isCompatible) {
                                        throw new TypeError(
                                            format("Argument %d: expected type '%s', got '%s'",
                                                   i + 1, paramType.toString(), argType.toString()),
                                            expr.arguments[i].location
                                        );
                                    }
                                }
                                
                                // Mark this as a UFCS call for the emitter
                                expr.isUFCS = true;
                                
                                return funcType.returnType;
                            }
                        }
                    }
                }
            }
        }
        
        Type funcType = checkExpression(expr.function_);
        
        auto functionType = cast(FunctionType)funcType;
        if (!functionType) {
            throw new TypeError(
                format("Cannot call non-function type '%s'", funcType.toString()),
                expr.function_.location
            );
        }
        
        // Special handling for builtin variadic functions
        bool isVariadicBuiltin = false;
        string funcName = "unknown";
        if (auto identExpr = cast(IdentifierExpression)expr.function_) {
            funcName = identExpr.name;
            isVariadicBuiltin = (funcName == "writeln" || funcName == "__writeln"); // CTFE writeln too
        }
        
        // Check argument count (skip for variadic builtins)
        if (!isVariadicBuiltin && expr.arguments.length != functionType.parameterTypes.length) {
            throw new TypeError(
                format("Function expects %d arguments, got %d",
                       functionType.parameterTypes.length, expr.arguments.length),
                expr.location
            );
        }
        
        // Check argument types (for variadic builtins, just validate argument expressions)
        if (isVariadicBuiltin) {
            // For variadic functions like writeln, just type-check the arguments
            // without enforcing specific parameter types
            for (size_t i = 0; i < expr.arguments.length; i++) {
                checkExpression(expr.arguments[i]); // Just validate the expression
            }
        } else {
            // Standard argument type checking for non-variadic functions
            for (size_t i = 0; i < expr.arguments.length; i++) {
                Type argType = checkExpression(expr.arguments[i]);
                Type paramType = functionType.parameterTypes[i];
                
                auto compat = checkTypeCompatibility(argType, paramType);
                if (!compat.isCompatible) {
                    throw new TypeError(
                        format("Argument %d: expected type '%s', got '%s'",
                               i + 1, paramType.toString(), argType.toString()),
                        expr.arguments[i].location
                    );
                }
            }
        }
        
        return functionType.returnType;
    }
    
    /**
     * Get a method from a struct by name, returns null if not found
     */
    FunctionDecl getStructMethod(StructDecl structDecl, string methodName) {
        foreach (member; structDecl.members) {
            if (auto funcDecl = cast(FunctionDecl)member) {
                if (funcDecl.name == methodName && funcDecl.isMethod) {
                    return funcDecl;
                }
            }
        }
        return null;
    }
    
    /**
     * Check struct construction expression (TypeName(args...))
     */
    Type checkStructConstruction(StructDecl structDecl, UserType userType, Expression[] arguments, SourceLocation loc) {
        // Check argument count matches field count
        if (arguments.length != structDecl.fields.length) {
            throw new TypeError(
                format("Struct '%s' has %d fields, got %d arguments",
                       structDecl.name, structDecl.fields.length, arguments.length),
                loc);
        }
        
        // Check each argument type matches the corresponding field type
        for (size_t i = 0; i < arguments.length; i++) {
            Type argType = checkExpression(arguments[i]);
            Type fieldType = structDecl.fields[i].type;
            
            if (fieldType) {
                auto compat = checkTypeCompatibility(argType, fieldType);
                if (!compat.isCompatible) {
                    throw new TypeError(
                        format("Cannot initialize field '%s' of type '%s' with value of type '%s'",
                               structDecl.fields[i].name, fieldType.toString(), argType.toString()),
                        arguments[i].location);
                }
            }
        }
        
        return userType;
    }
    
    /**
     * Check unary expression types
     */
    Type checkUnaryExpression(UnaryExpression expr) {
        Type operandType = checkExpression(expr.operand);
        
        final switch (expr.operator) {
            case UnaryExpression.Operator.Plus:
            case UnaryExpression.Operator.Minus:
                // Arithmetic unary operators require numeric type
                if (!isNumericType(operandType)) {
                    throw new TypeError(
                        format("Unary %s requires numeric type, got '%s'",
                               expr.operator == UnaryExpression.Operator.Plus ? "+" : "-",
                               operandType.toString()),
                        expr.location);
                }
                return operandType;
                
            case UnaryExpression.Operator.LogicalNot:
                // Logical not requires boolean-convertible type
                if (!isBooleanConvertible(operandType)) {
                    throw new TypeError(
                        format("Logical not requires boolean-convertible type, got '%s'",
                               operandType.toString()),
                        expr.location);
                }
                return new BasicType(expr.location, BasicType.Kind.Bool);
                
            case UnaryExpression.Operator.BitwiseNot:
                // Bitwise not requires integral type
                if (!isIntegralType(operandType)) {
                    throw new TypeError(
                        format("Bitwise not requires integral type, got '%s'",
                               operandType.toString()),
                        expr.location);
                }
                return operandType;
                
            case UnaryExpression.Operator.PreIncrement:
            case UnaryExpression.Operator.PostIncrement:
            case UnaryExpression.Operator.PreDecrement:
            case UnaryExpression.Operator.PostDecrement:
                // Increment/decrement require numeric lvalue
                if (!isNumericType(operandType)) {
                    throw new TypeError(
                        format("Increment/decrement requires numeric type, got '%s'",
                               operandType.toString()),
                        expr.location);
                }
                // TODO: Check that operand is an lvalue
                return operandType;
                
            case UnaryExpression.Operator.AddressOf:
                // Returns pointer to operand type
                return new PointerType(expr.location, operandType);
                
            case UnaryExpression.Operator.Dereference:
                // Requires pointer type, returns pointed-to type
                if (auto ptrType = cast(PointerType)operandType) {
                    return ptrType.pointeeType;
                }
                throw new TypeError(
                    format("Cannot dereference non-pointer type '%s'",
                           operandType.toString()),
                    expr.location);
        }
    }
    
    Type checkIndexExpression(IndexExpression expr) {
        Type arrayType = checkExpression(expr.array);
        Type indexType = checkExpression(expr.index);
        
        // Check that index is an integer type
        auto basicIndexType = cast(BasicType)indexType;
        if (!basicIndexType || !isIntegerType(basicIndexType)) {
            throw new TypeError(
                format("Array index must be integer type, got '%s'", indexType.toString()),
                expr.index.location);
        }
        
        // For array types, indexing goes through opIndex (built-in intrinsic)
        if (auto arrType = cast(ArrayType)arrayType) {
            // Look up the built-in opIndex method
            auto opIndex = symbolTable.lookupBuiltinMethod("array", "opIndex");
            if (opIndex) {
                // Mark this expression as using opIndex for the emitter
                expr.usesOpIndex = true;
                expr.opIndexMethod = opIndex;
            }
            return arrType.elementType;
        }
        
        throw new TypeError(
            format("Cannot index non-array type '%s'", arrayType.toString()),
            expr.location);
    }
    
    /**
     * Type check slice expression arr[start..end]
     * Returns the same array type (a view into the original array)
     */
    Type checkSliceExpression(SliceExpression expr) {
        Type arrayType = checkExpression(expr.array);
        Type startType = checkExpression(expr.start);
        Type endType = checkExpression(expr.end);
        
        // Check that start and end are integers
        if (!isIntegerType(cast(BasicType)startType)) {
            throw new TypeError(
                format("Slice start must be integer type, got '%s'", startType.toString()),
                expr.start.location);
        }
        if (!isIntegerType(cast(BasicType)endType)) {
            throw new TypeError(
                format("Slice end must be integer type, got '%s'", endType.toString()),
                expr.end.location);
        }
        
        // Array slicing returns the same array type (a view)
        if (auto arrType = cast(ArrayType)arrayType) {
            return arrType;  // Same type - it's a view
        }
        
        throw new TypeError(
            format("Cannot slice non-array type '%s'", arrayType.toString()),
            expr.location);
    }
    
    /**
     * Type check import expression: import("filename")
     * Returns ubyte[] - the file contents as raw bytes.
     * This is CTFE-only - the file is read at compile time.
     */
    Type checkImportExpression(ImportExpression expr) {
        // import() returns ubyte[] (raw file bytes)
        auto ubyteType = new BasicType(expr.location, BasicType.Kind.UInt8);
        return new ArrayType(expr.location, ubyteType);
    }
    
    Type checkMemberExpression(MemberExpression expr) {
        // Check if the object is a type name (for Type.sizeof, Type.alignof, etc.)
        if (auto ident = cast(IdentifierExpression)expr.object) {
            auto symbol = symbolTable.lookupSymbol(ident.name);
            if (symbol && symbol.kind == SymbolKind.Type) {
                // It's a type property access
                if (expr.memberName == "sizeof") {
                    // Type.sizeof returns a compile-time integer
                    return new BasicType(expr.location, BasicType.Kind.Int32);
                } else if (expr.memberName == "alignof") {
                    // Type.alignof returns a compile-time integer
                    return new BasicType(expr.location, BasicType.Kind.Int32);
                } else {
                    throw new TypeError(
                        format("Type '%s' has no property '%s'", ident.name, expr.memberName),
                        expr.location);
                }
            }
        }
        
        // Check the object expression
        Type objectType = checkExpression(expr.object);
        
        // Handle struct field access
        if (auto userType = cast(UserType)objectType) {
            // Special handling for string type (.length, .ptr)
            if (userType.name == "string") {
                if (expr.memberName == "length") {
                    return new BasicType(expr.location, BasicType.Kind.UInt64);
                } else if (expr.memberName == "ptr") {
                    return new PointerType(expr.location, new BasicType(expr.location, BasicType.Kind.Char));
                }
            }
            
            // Resolve the UserType's declaration if not already linked
            if (!userType.declaration) {
                auto typeSymbol = symbolTable.lookupSymbol(userType.name);
                if (typeSymbol && typeSymbol.kind == SymbolKind.Type) {
                    userType.declaration = typeSymbol.declaration;
                }
            }
            
            if (auto structDecl = cast(StructDecl)userType.declaration) {
                auto field = structDecl.getField(expr.memberName);
                if (field) {
                    return field.type;
                }
                throw new TypeError(
                    format("Struct '%s' has no field '%s'", userType.name, expr.memberName),
                    expr.location);
            }
        }
        
        // Handle array/slice .length, .ptr, .capacity
        if (auto arrayType = cast(ArrayType)objectType) {
            if (expr.memberName == "length") {
                return new BasicType(expr.location, BasicType.Kind.Int32);
            } else if (expr.memberName == "ptr") {
                return new PointerType(expr.location, arrayType.elementType);
            } else if (expr.memberName == "capacity") {
                return new BasicType(expr.location, BasicType.Kind.Int32);
            }
        }
        
        throw new TypeError(
            format("Cannot access member '%s' on type '%s'", expr.memberName, objectType.toString()),
            expr.location);
    }
    
    Type checkCastExpression(CastExpression expr) {
        checkExpression(expr.expression);  // Verify source expression is valid
        return expr.targetType;  // Cast always produces target type
    }
    
    Type checkAssignmentExpression(AssignmentExpression expr) {
        Type leftType = checkExpression(expr.left);
        Type rightType = checkExpression(expr.right);
        
        // Special case: ~= on arrays appends an element
        if (expr.operator == AssignmentExpression.Operator.ConcatAssign) {
            if (auto arrayType = cast(ArrayType)leftType) {
                // Right side should be compatible with element type
                auto compat = checkTypeCompatibility(rightType, arrayType.elementType);
                if (!compat.isCompatible) {
                    throw new TypeError(
                        format("Cannot append type '%s' to array of '%s'",
                               rightType.toString(), arrayType.elementType.toString()),
                        expr.location
                    );
                }
                return leftType;  // ~= returns the array
            }
            throw new TypeError(
                format("Cannot use ~= on non-array type '%s'", leftType.toString()),
                expr.location
            );
        }
        
        auto compat = checkTypeCompatibility(rightType, leftType);
        if (!compat.isCompatible) {
            throw new TypeError(
                format("Cannot assign type '%s' to '%s'",
                       rightType.toString(), leftType.toString()),
                expr.location
            );
        }
        
        return leftType;  // Assignment expression has type of left-hand side
    }
    
    /**
     * Type check array literal expression [1, 2, 3]
     * Returns a dynamic array (slice) type.
     */
    Type checkArrayLiteralExpression(ArrayLiteralExpression expr) {
        if (expr.elements.length == 0) {
            // Empty array literal - can't infer type without context
            // For now, default to int[]
            return new ArrayType(expr.location, new BasicType(expr.location, BasicType.Kind.Int32));
        }
        
        // Infer element type from first element
        Type elementType = checkExpression(expr.elements[0]);
        
        // Check all elements have compatible types
        for (size_t i = 1; i < expr.elements.length; i++) {
            Type elemType = checkExpression(expr.elements[i]);
            auto compat = checkTypeCompatibility(elemType, elementType);
            if (!compat.isCompatible) {
                throw new TypeError(
                    format("Array literal element %d has type '%s', expected '%s'",
                           i, elemType.toString(), elementType.toString()),
                    expr.elements[i].location
                );
            }
        }
        
        // Store inferred type in the expression
        expr.elementType = elementType;
        
        // Return dynamic array type (slice)
        return new ArrayType(expr.location, elementType);
    }
    
    /**
     * Check if two types are compatible
     */
    TypeCompatibility checkTypeCompatibility(Type from, Type to) {
        // Exact type match
        if (typesEqual(from, to)) {
            return TypeCompatibility.compatible();
        }
        
        // Both are basic types - check for implicit conversions
        auto fromBasic = cast(BasicType)from;
        auto toBasic = cast(BasicType)to;
        
        if (fromBasic && toBasic) {
            return checkBasicTypeCompatibility(fromBasic, toBasic);
        }
        
        // Array type compatibility
        auto fromArray = cast(ArrayType)from;
        auto toArray = cast(ArrayType)to;
        
        if (fromArray && toArray) {
            // Check element type compatibility
            auto elemCompat = checkTypeCompatibility(fromArray.elementType, toArray.elementType);
            if (!elemCompat.isCompatible) {
                return TypeCompatibility.incompatible();
            }
            
            // Dynamic array → static array is allowed (array literal init)
            // The actual length check happens at runtime or is checked by emitter
            if (fromArray.arraySize is null && toArray.arraySize !is null) {
                return TypeCompatibility.compatible();
            }
            
            // Static → static with same size is compatible
            // (would need to evaluate both sizes to check equality)
            if (fromArray.arraySize !is null && toArray.arraySize !is null) {
                return TypeCompatibility.compatible();  // Assume compatible, could add size check
            }
            
            // Same kind (both dynamic or both static)
            return TypeCompatibility.compatible();
        }
        
        return TypeCompatibility.incompatible();
    }
    
    /**
     * Check compatibility between basic types
     */
    TypeCompatibility checkBasicTypeCompatibility(BasicType from, BasicType to) {
        // Identical types
        if (from.kind == to.kind) {
            return TypeCompatibility.compatible();
        }
        
        // Integer promotions and conversions
        if (isIntegerType(from) && isIntegerType(to)) {
            // Allow implicit conversions that don't lose precision
            if (getTypeSize(from) <= getTypeSize(to)) {
                // Also check signedness compatibility
                if (isSignedInteger(from) == isSignedInteger(to) ||
                    getTypeSize(from) < getTypeSize(to)) {
                    return TypeCompatibility.withConversion(to);
                }
            }
        }
        
        // Integer to float conversion
        if (isIntegerType(from) && isFloatingType(to)) {
            return TypeCompatibility.withConversion(to);
        }
        
        // Float to higher precision float
        if (isFloatingType(from) && isFloatingType(to)) {
            if (getTypeSize(from) <= getTypeSize(to)) {
                return TypeCompatibility.withConversion(to);
            }
        }
        
        return TypeCompatibility.incompatible();
    }
    
    /**
     * Promote two arithmetic types to common type
     */
    Type promoteArithmeticTypes(Type left, Type right, SourceLocation location) {
        auto leftBasic = cast(BasicType)left;
        auto rightBasic = cast(BasicType)right;
        
        if (!leftBasic || !rightBasic) {
            throw new TypeError("Cannot promote non-basic types", location);
        }
        
        // If either is floating point, result is floating point
        if (isFloatingType(leftBasic) || isFloatingType(rightBasic)) {
            if (isFloatingType(leftBasic) && isFloatingType(rightBasic)) {
                // Both floating - use higher precision
                return getTypeSize(leftBasic) >= getTypeSize(rightBasic) ? left : right;
            } else if (isFloatingType(leftBasic)) {
                return left;
            } else {
                return right;
            }
        }
        
        // Both integers - promote to larger type
        if (getTypeSize(leftBasic) >= getTypeSize(rightBasic)) {
            return left;
        } else {
            return right;
        }
    }
    
    /**
     * Type utility functions
     */
    bool typesEqual(Type a, Type b) {
        if (a is b) return true;
        if (!a || !b) return false;
        // Simplified equality check - in a full implementation this would be more sophisticated
        return a.toString() == b.toString();
    }
    
    bool isArithmeticType(Type type) {
        if (!type) return false;
        auto basic = cast(BasicType)type;
        return basic && (isIntegerType(basic) || isFloatingType(basic));
    }
    
    bool isNumericType(Type type) {
        return isArithmeticType(type);
    }
    
    bool isIntegralType(Type type) {
        if (!type) return false;
        auto basic = cast(BasicType)type;
        return basic && isIntegerType(basic);
    }
    
    bool isIntegerType(BasicType type) {
        switch (type.kind) {
            case BasicType.Kind.Int8:
            case BasicType.Kind.Int16:
            case BasicType.Kind.Int32:
            case BasicType.Kind.Int64:
            case BasicType.Kind.UInt8:
            case BasicType.Kind.UInt16:
            case BasicType.Kind.UInt32:
            case BasicType.Kind.UInt64:
                return true;
            default:
                return false;
        }
    }
    
    bool isFloatingType(BasicType type) {
        return type.kind == BasicType.Kind.Float32 || type.kind == BasicType.Kind.Float64;
    }
    
    bool isSignedInteger(BasicType type) {
        switch (type.kind) {
            case BasicType.Kind.Int8:
            case BasicType.Kind.Int16:
            case BasicType.Kind.Int32:
            case BasicType.Kind.Int64:
                return true;
            default:
                return false;
        }
    }
    
    bool isBooleanConvertible(Type type) {
        // D requires strict bool - no implicit conversion from int/float
        auto basic = cast(BasicType)type;
        if (basic) {
            return basic.kind == BasicType.Kind.Bool;
        }
        return false;
    }
    
    bool isVoidType(Type type) {
        if (!type) return false;
        auto basic = cast(BasicType)type;
        return basic && basic.kind == BasicType.Kind.Void;
    }
    
    uint getTypeSize(BasicType type) {
        switch (type.kind) {
            case BasicType.Kind.Bool:
            case BasicType.Kind.Int8:
            case BasicType.Kind.UInt8:
            case BasicType.Kind.Char:
                return 1;
            case BasicType.Kind.Int16:
            case BasicType.Kind.UInt16:
                return 2;
            case BasicType.Kind.Int32:
            case BasicType.Kind.UInt32:
            case BasicType.Kind.Float32:
                return 4;
            case BasicType.Kind.Int64:
            case BasicType.Kind.UInt64:
            case BasicType.Kind.Float64:
                return 8;
            default:
                return 0;
        }
    }
    
    /**
     * Infer type for literal expressions based on their value
     */
    Type inferLiteralType(LiteralExpression literal) {
        import std.variant;
        
        if (literal.value.type == typeid(long)) {
            // Integer literal
            return new BasicType(literal.location, BasicType.Kind.Int32);
        } else if (literal.value.type == typeid(double)) {
            // Floating point literal
            return new BasicType(literal.location, BasicType.Kind.Float64);
        } else if (literal.value.type == typeid(bool)) {
            // Boolean literal
            return new BasicType(literal.location, BasicType.Kind.Bool);
        } else if (literal.value.type == typeid(string)) {
            // String literal - treat as ubyte[] (raw bytes, no string semantics)
            auto ubyteType = new BasicType(literal.location, BasicType.Kind.UInt8);
            return new ArrayType(literal.location, ubyteType);
        } else if (literal.value.type == typeid(typeof(null))) {
            // Null literal
            return new BasicType(literal.location, BasicType.Kind.Void);  // TODO: Proper null type
        } else {
            throw new TypeError(
                format("Unknown literal type: %s", literal.value.type),
                literal.location
            );
        }
    }
}