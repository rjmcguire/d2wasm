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
    
    this(SymbolTable symbolTable) {
        this.symbolTable = symbolTable;
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
        writeln("Type checking function: ", decl.name);
        
        // Skip CTFE-only functions (functions that return string type)
        // These are only used at compile time for mixin expansion
        if (auto userType = cast(UserType)decl.returnType) {
            if (userType.name == "string") {
                writeln("Skipping type check for CTFE-only function: ", decl.name);
                return;
            }
        }
        
        // Enter function scope
        if (!symbolTable) { writeln("Error: symbolTable is null!"); return; }
        symbolTable.enterScope("function:" ~ decl.name);
        scope(exit) symbolTable.exitScope();
        
        // Set current return type for return statement checking
        Type oldReturnType = currentFunctionReturnType;
        currentFunctionReturnType = decl.returnType;
        scope(exit) currentFunctionReturnType = oldReturnType;
        
        // Add parameters to scope
        writeln("Checking parameters for ", decl.name);
        foreach (param; decl.parameters) {
            writeln("  Parameter: ", param.name);
            
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
            writeln("Checking body for ", decl.name);
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
            writeln("Warning: visiting null statement in TypeChecker");
            return;
        }
        // writeln("Checking statement type: ", typeid(stmt).name);
        
        if (auto compound = cast(CompoundStatement)stmt) {
            symbolTable.enterScope("block");
            scope(exit) symbolTable.exitScope();
            
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
            symbolTable.addSymbol(symbol);
        }
    }
    
    /**
     * Type check an expression and return its type
     */
    Type checkExpression(Expression expr) {
        if (!expr) {
            writeln("Error: visiting null expression in TypeChecker");
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
        
        // Bitwise operators - TODO: implement
        throw new TypeError(
            format("Bitwise operators not yet implemented"),
            expr.location
        );
    }
    
    /**
     * Type check identifier expression
     */
    Type checkIdentifierExpression(IdentifierExpression expr) {
        Symbol symbol = symbolTable.lookupSymbol(expr.name);
        if (!symbol) {
            throw new TypeError(
                format("Undefined identifier '%s'", expr.name),
                expr.location
            );
        }
        
        return symbol.type;
    }
    
    /**
     * Type check call expression
     */
    Type checkCallExpression(CallExpression expr) {
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
        throw new TypeError("Index expressions not yet implemented", expr.location);
    }
    
    Type checkMemberExpression(MemberExpression expr) {
        throw new TypeError("Member expressions not yet implemented", expr.location);
    }
    
    Type checkCastExpression(CastExpression expr) {
        checkExpression(expr.expression);  // Verify source expression is valid
        return expr.targetType;  // Cast always produces target type
    }
    
    Type checkAssignmentExpression(AssignmentExpression expr) {
        Type leftType = checkExpression(expr.left);
        Type rightType = checkExpression(expr.right);
        
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
        
        // TODO: Add more type compatibility rules (pointers, arrays, user types)
        
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
            // String literal - return as UserType "string" for now
            return new UserType(literal.location, "string");
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