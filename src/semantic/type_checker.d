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
import semantic.template_instantiation;
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
    private StructDecl currentStructDecl;  // Non-null when inside a struct method
    private ClassDecl currentClassDecl;    // Non-null when inside a class method
    private FunctionDecl currentFunctionDecl;  // Current function being type-checked

    // Template instantiation driver — shared across all type-checking in this compilation
    TemplateInstantiator templateInstantiator;

    // Alias-this recursion guard (prevents infinite loops on cyclic alias-this chains)
    private int aliasThisDepth;

    this(SymbolTable symbolTable) {
        this.symbolTable = symbolTable;
        this.templateInstantiator = new TemplateInstantiator();
        this.templateInstantiator.constraintEvaluator = symbolTable.constraintEvaluator;
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
        if (auto tmplDecl = cast(TemplateDecl)decl) {
            // Skip — templates are type-checked when instantiated
            return;
        } else if (auto funcDecl = cast(FunctionDecl)decl) {
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

        // Skip uninstantiated template functions — they are type-checked
        // when instantiated with concrete types
        if (decl.isTemplate) {
            return;
        }

        log(3, "Type checking function: ", decl.name);
        
        // Note: CTFE-only functions (e.g. those returning ubyte[] for mixin)
        // are still type-checked normally — no special skipping needed.
        
        // Enter function scope
        if (!symbolTable) { log(1, "Error: symbolTable is null!"); return; }
        symbolTable.enterScope("function:" ~ decl.name);
        scope(exit) symbolTable.exitScope();
        
        // Reset unique local ID counter for this function
        symbolTable.nextLocalId = 0;
        
        // Resolve transparent type aliases in return type and parameters,
        // then resolve any resulting UserTypes (template instantiation or declaration linking)
        decl.returnType = resolveAliasType(decl.returnType);
        resolveUserType(decl.returnType);
        foreach (ref param; decl.parameters) {
            param.type = resolveAliasType(param.type);
            resolveUserType(param.type);
        }

        // Set current return type and function decl for checking
        Type oldReturnType = currentFunctionReturnType;
        currentFunctionReturnType = decl.returnType;
        scope(exit) currentFunctionReturnType = oldReturnType;

        FunctionDecl oldFuncDecl = currentFunctionDecl;
        currentFunctionDecl = decl;
        scope(exit) currentFunctionDecl = oldFuncDecl;
        
        // Set current struct/class if this is a method
        StructDecl oldStructDecl = currentStructDecl;
        ClassDecl oldClassDecl = currentClassDecl;
        if (decl.isMethod) {
            currentStructDecl = cast(StructDecl)decl.parent;
            currentClassDecl = cast(ClassDecl)decl.parent;
        }
        scope(exit) {
            currentStructDecl = oldStructDecl;
            currentClassDecl = oldClassDecl;
        }
        
        // Add parameters to scope and assign unique IDs
        log(3, "Checking parameters for ", decl.name);
        foreach (i, ref param; decl.parameters) {
            log(3, "  Parameter: ", param.name);
            
            // Assign unique local ID
            param.uniqueLocalId = symbolTable.allocateLocalId();
            
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
        // Resolve transparent type aliases, then link UserType declarations
        decl.type = resolveAliasType(decl.type);
        resolveUserType(decl.type);

        // Type check initializer if present
        if (decl.initializer) {
            Type initType = checkExpression(decl.initializer);
            auto compat = checkTypeCompatibility(initType, decl.type);
            if (!compat.isCompatible) {
                // Try alias-this unwrapping
                if (tryAliasThisUnwrap(decl.initializer, initType, decl.type)) {
                    return;  // Rewritten successfully
                }
                throw new TypeError(
                    format("Initializer type '%s' is not compatible with variable type '%s'",
                           initType.toString(), decl.type.toString()),
                    decl.initializer.location
                );
            }
        }
    }
    
    /**
     * Type check class declaration
     */
    void checkClassDeclaration(ClassDecl decl) {
        symbolTable.enterScope("class:" ~ decl.name);
        scope(exit) symbolTable.exitScope();
        
        // Resolve base class if present
        if (decl.baseClass) {
            if (auto userType = cast(UserType)decl.baseClass) {
                auto typeSymbol = symbolTable.lookupSymbol(userType.name);
                if (typeSymbol && typeSymbol.kind == SymbolKind.Type) {
                    if (auto baseClassDecl = cast(ClassDecl)typeSymbol.declaration) {
                        decl.baseClassDecl = baseClassDecl;
                        userType.declaration = baseClassDecl;
                        
                        // Validate: can't inherit from self
                        if (baseClassDecl is decl) {
                            throw new TypeError("Class cannot inherit from itself: " ~ decl.name, decl.location);
                        }
                        
                        // Check for circular inheritance (A : B, B : A)
                        ClassDecl walker = baseClassDecl;
                        while (walker.baseClassDecl) {
                            walker = walker.baseClassDecl;
                            if (walker is decl) {
                                throw new TypeError(
                                    "Circular inheritance detected: " ~ decl.name ~ " -> ... -> " ~ decl.name,
                                    decl.location);
                            }
                        }
                    } else if (auto ifaceDecl = cast(InterfaceDecl)typeSymbol.declaration) {
                        // First item is an interface, not a base class
                        // Move it to interfaces list and clear baseClass
                        decl.interfaces = [decl.baseClass] ~ decl.interfaces;
                        decl.baseClass = null;
                        userType.declaration = ifaceDecl;
                    } else {
                        throw new TypeError("Base class must be a class, not a struct: " ~ userType.name, decl.location);
                    }
                } else {
                    throw new TypeError("Unknown base class: " ~ userType.name, decl.location);
                }
            }
        }
        
        // Type check members
        foreach (member; decl.members) {
            checkDeclaration(member);
        }
        
        // Validate method overrides if we have a base class
        if (decl.baseClassDecl) {
            validateOverrides(decl);
        }
        
        // Validate interface implementations
        foreach (ifaceType; decl.interfaces) {
            if (auto userType = cast(UserType)ifaceType) {
                if (!userType.declaration) {
                    auto sym = symbolTable.lookupSymbol(userType.name);
                    if (sym && sym.kind == SymbolKind.Type) {
                        userType.declaration = sym.declaration;
                    }
                }
                if (auto ifaceDecl = cast(InterfaceDecl)userType.declaration) {
                    validateInterfaceImplementation(decl, ifaceDecl);
                }
            }
        }
    }
    
    /**
     * Validate that a class implements all methods of an interface
     */
    private void validateInterfaceImplementation(ClassDecl classDecl, InterfaceDecl ifaceDecl) {
        foreach (ifaceMethod; ifaceDecl.methods) {
            // Find matching method in class (including inherited)
            auto classMethod = findMethodInClass(classDecl, ifaceMethod.name);
            if (!classMethod) {
                throw new TypeError(
                    format("Class '%s' does not implement interface method '%s' from '%s'",
                           classDecl.name, ifaceMethod.name, ifaceDecl.name),
                    classDecl.location);
            }
            
            // Validate signature matches
            if (!signaturesMatch(classMethod, ifaceMethod)) {
                throw new TypeError(
                    format("Method '%s' in class '%s' has wrong signature for interface '%s'",
                           ifaceMethod.name, classDecl.name, ifaceDecl.name),
                    classMethod.location);
            }
        }
    }
    
    /**
     * Find a method in a class (including inherited methods)
     */
    private FunctionDecl findMethodInClass(ClassDecl classDecl, string methodName) {
        // Check class's own methods first
        foreach (member; classDecl.members) {
            if (auto method = cast(FunctionDecl)member) {
                if (method.name == methodName && !method.isConstructor && !method.isDestructor) {
                    return method;
                }
            }
        }
        // Check inherited methods
        if (classDecl.baseClassDecl) {
            return findMethodInClass(classDecl.baseClassDecl, methodName);
        }
        return null;
    }
    
    /**
     * Check if a class implements an interface (directly or through inheritance)
     */
    private bool classImplementsInterface(ClassDecl classDecl, InterfaceDecl ifaceDecl) {
        // Check class's direct interfaces
        foreach (ifaceType; classDecl.interfaces) {
            if (auto userType = cast(UserType)ifaceType) {
                if (userType.declaration is ifaceDecl) {
                    return true;
                }
                // Also resolve if not yet resolved
                if (!userType.declaration) {
                    auto sym = symbolTable.lookupSymbol(userType.name);
                    if (sym && sym.kind == SymbolKind.Type) {
                        userType.declaration = sym.declaration;
                        if (userType.declaration is ifaceDecl) {
                            return true;
                        }
                    }
                }
            }
        }
        // Check base class
        if (classDecl.baseClassDecl) {
            return classImplementsInterface(classDecl.baseClassDecl, ifaceDecl);
        }
        return false;
    }
    
    /**
     * Validate that method overrides have matching signatures
     */
    private void validateOverrides(ClassDecl decl) {
        foreach (member; decl.members) {
            if (auto method = cast(FunctionDecl)member) {
                if (method.isConstructor || method.isDestructor) continue;
                
                // Check if base class has a method with the same name
                auto baseMethod = findMethodInHierarchy(decl.baseClassDecl, method.name);
                if (baseMethod) {
                    // Validate signature matches (simple check for now)
                    if (!signaturesMatch(method, baseMethod)) {
                        throw new TypeError(
                            "Override signature mismatch for method '" ~ method.name ~ 
                            "' - must match base class", method.location);
                    }
                }
            }
        }
    }
    
    /**
     * Find a method by name in the class hierarchy
     */
    private FunctionDecl findMethodInHierarchy(ClassDecl classDecl, string methodName) {
        while (classDecl) {
            foreach (member; classDecl.members) {
                if (auto method = cast(FunctionDecl)member) {
                    if (method.name == methodName && !method.isConstructor && !method.isDestructor) {
                        return method;
                    }
                }
            }
            classDecl = classDecl.baseClassDecl;
        }
        return null;
    }
    
    /**
     * Check if two method signatures match (return type and parameters)
     */
    private bool signaturesMatch(FunctionDecl a, FunctionDecl b) {
        // Check parameter count
        if (a.parameters.length != b.parameters.length) return false;
        
        // Check parameter types
        foreach (i, param; a.parameters) {
            if (!typesMatch(param.type, b.parameters[i].type)) return false;
        }
        
        // Check return type
        return typesMatch(a.returnType, b.returnType);
    }
    
    /**
     * Check if two types match (simple structural comparison)
     */
    private bool typesMatch(Type a, Type b) {
        if (a is null && b is null) return true;
        if (a is null || b is null) return false;
        
        // Compare basic types
        if (auto pa = cast(BasicType)a) {
            if (auto pb = cast(BasicType)b) {
                return pa.kind == pb.kind;
            }
            return false;
        }
        
        // Compare user types by name (could be more sophisticated)
        if (auto ua = cast(UserType)a) {
            if (auto ub = cast(UserType)b) {
                return ua.name == ub.name;
            }
            return false;
        }
        
        // For other types, fall back to string comparison
        return a.toString() == b.toString();
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
        if (decl.baseType is null) return;  // default int, no range check needed

        auto basic = cast(BasicType)decl.baseType;
        if (basic is null) return;  // user-defined base type, skip for now

        foreach (member; decl.members) {
            if (member.value is null) continue;  // auto-incremented
            if (auto lit = cast(LiteralExpression)member.value) {
                if (lit.value.type == typeid(long)) {
                    long val = lit.value.get!long();
                    if (!fitsInBasicType(val, basic.kind)) {
                        throw new TypeError(
                            format("Enum member '%s' value %d does not fit in base type '%s'",
                                   member.name, val, basic.toString()),
                            decl.location);
                    }
                }
            }
        }
    }

    private static bool fitsInBasicType(long val, BasicType.Kind kind) {
        final switch (kind) {
            case BasicType.Kind.Int8:    return val >= -128 && val <= 127;
            case BasicType.Kind.UInt8:   return val >= 0 && val <= 255;
            case BasicType.Kind.Char:    return val >= 0 && val <= 255;
            case BasicType.Kind.Int16:   return val >= -32_768 && val <= 32_767;
            case BasicType.Kind.UInt16:  return val >= 0 && val <= 65_535;
            case BasicType.Kind.Int32:   return val >= int.min && val <= int.max;
            case BasicType.Kind.UInt32:  return val >= 0 && val <= uint.max;
            case BasicType.Kind.Int64:   return true;  // long fits in long
            case BasicType.Kind.UInt64:  return val >= 0;
            case BasicType.Kind.Bool:    return val == 0 || val == 1;
            case BasicType.Kind.Float32: return true;
            case BasicType.Kind.Float64: return true;
            case BasicType.Kind.Void:    return false;
        }
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
            scope(exit) {
                compound.destructOnExit = symbolTable.popScopeVars();
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
            returnStmt.unwindChain = symbolTable.getUnwindChain();
            
            if (returnStmt.value) {
                Type returnType = checkExpression(returnStmt.value);
                if (!currentFunctionReturnType) {
                    throw new TypeError("Return statement outside of any function", returnStmt.location);
                }
                auto compat = checkTypeCompatibility(returnType, currentFunctionReturnType);
                if (!compat.isCompatible) {
                    // Try alias-this unwrapping
                    if (!tryAliasThisUnwrap(returnStmt.value, returnType, currentFunctionReturnType)) {
                        throw new TypeError(
                            format("Return type '%s' is not compatible with function return type '%s'",
                                   returnType.toString(), currentFunctionReturnType.toString()),
                            returnStmt.value.location
                        );
                    }
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
            varDeclStmt.uniqueLocalId = symbolTable.allocateLocalId();

            // Track for RAII unwind
            symbolTable.trackScopeVar(varDeclStmt.uniqueLocalId);
            
            // Resolve transparent type aliases (skip for auto declarations where type is null)
            varDeclStmt.type = resolveAliasType(varDeclStmt.type);

            // Link UserType to its declaration (skip for auto declarations)
            if (varDeclStmt.type !is null) {
                if (auto userType = cast(UserType)varDeclStmt.type) {
                    if (userType.templateArgs.length > 0) {
                        // Template type: Pair!(int, int) — instantiate the template
                        resolveTemplateUserType(userType);
                    } else if (!userType.declaration) {
                        auto typeSymbol = symbolTable.lookupSymbol(userType.name);
                        if (typeSymbol && typeSymbol.kind == SymbolKind.Type) {
                            userType.declaration = typeSymbol.declaration;
                        }
                    }
                    assert(userType.declaration !is null,
                        "Failed to resolve type '" ~ userType.name ~ "' for variable '" ~ varDeclStmt.name ~ "'");
                }
            }

            // Type check initializer if present
            if (varDeclStmt.initializer) {
                Type initType = checkExpression(varDeclStmt.initializer);
                if (varDeclStmt.type is null) {
                    // auto type inference
                    varDeclStmt.type = initType;
                } else {
                    auto compat = checkTypeCompatibility(initType, varDeclStmt.type);
                    if (!compat.isCompatible) {
                        // Try alias-this unwrapping
                        if (!tryAliasThisUnwrap(varDeclStmt.initializer, initType, varDeclStmt.type)) {
                            throw new TypeError(
                                format("Initializer type '%s' is not compatible with variable type '%s'",
                                       initType.toString(), varDeclStmt.type.toString()),
                                varDeclStmt.initializer.location
                            );
                        }
                    }
                }
            }
            // Add the variable to the symbol table
            auto symbol = new Symbol(varDeclStmt.name, SymbolKind.Variable, varDeclStmt.type, 
                                     null, varDeclStmt.location, false);
            symbol.uniqueLocalId = varDeclStmt.uniqueLocalId;
            symbolTable.addSymbol(symbol);
        } else if (auto structStmt = cast(StructDeclarationStatement)stmt) {
            // Inner struct declaration — compute layout and register type symbol
            auto collector = new SymbolCollector(symbolTable);
            collector.collectStructSymbol(structStmt.structDecl);
            // Type check struct members (methods, etc.)
            checkStructDeclaration(structStmt.structDecl);
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
        } else if (auto traits = cast(TraitsExpression)expr) {
            return checkTraitsExpression(traits);
        } else if (auto isExpr = cast(IsExpression)expr) {
            return checkIsExpression(isExpr);
        } else if (auto tmplInst = cast(TemplateInstantiationExpression)expr) {
            return checkTemplateInstantiation(tmplInst);
        } else if (auto newExpr = cast(NewExpression)expr) {
            return checkNewExpression(newExpr);
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

            // Struct comparison: lower to field-wise == or user-defined opEquals
            if ((expr.operator == BinaryExpression.Operator.Equal ||
                 expr.operator == BinaryExpression.Operator.NotEqual)) {
                auto leftStruct = leftType.asStruct();
                auto rightStruct = rightType.asStruct();
                if (leftStruct !is null && rightStruct !is null && leftStruct is rightStruct) {
                    expr.loweredCall = synthesizeStructEquals(expr, leftStruct);
                    return new BasicType(expr.location, BasicType.Kind.Bool);
                }
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
        // Shift operators — lower to checked operator function calls
        if (expr.operator == BinaryExpression.Operator.ShiftLeft ||
            expr.operator == BinaryExpression.Operator.ShiftRight ||
            expr.operator == BinaryExpression.Operator.UnsignedShiftRight) {

            if (!isIntegerType(cast(BasicType)leftType.resolve()) || !isIntegerType(cast(BasicType)rightType.resolve())) {
                throw new TypeError(
                    format("Shift operator requires integer types, got '%s' and '%s'",
                           leftType.toString(), rightType.toString()),
                    expr.location
                );
            }

            // Lower to checked operator function call
            string funcName;
            if (expr.operator == BinaryExpression.Operator.ShiftLeft)
                funcName = "opShiftLeft";
            else if (expr.operator == BinaryExpression.Operator.ShiftRight)
                funcName = "opShiftRight";
            else
                funcName = "opUnsignedShiftRight";

            auto callExpr = new CallExpression(expr.location,
                new IdentifierExpression(expr.location, funcName),
                [expr.left, expr.right]);
            Type resultType = checkCallExpression(callExpr);
            expr.loweredCall = callExpr;
            return resultType;
        }

        // Bitwise operators (non-shift)
        if (expr.operator == BinaryExpression.Operator.BitwiseAnd ||
            expr.operator == BinaryExpression.Operator.BitwiseOr ||
            expr.operator == BinaryExpression.Operator.BitwiseXor) {

            if (!isIntegerType(cast(BasicType)leftType.resolve()) || !isIntegerType(cast(BasicType)rightType.resolve())) {
                throw new TypeError(
                    format("Bitwise operator requires integer types, got '%s' and '%s'",
                           leftType.toString(), rightType.toString()),
                    expr.location
                );
            }

            return leftType;  // Result is same type as left operand
        }

        // Concatenation operator (~)
        if (expr.operator == BinaryExpression.Operator.Concat) {
            if (auto arrType = cast(ArrayType)leftType) {
                return arrType;
            }
            throw new TypeError(
                format("Concatenation operator requires array type, got '%s'",
                       leftType.toString()),
                expr.location
            );
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
            if (!currentStructDecl && !currentClassDecl) {
                throw new TypeError("'this' can only be used inside a method", expr.location);
            }
            // 'this' has the type of the enclosing struct/class
            if (currentClassDecl) {
                auto thisType = new UserType(expr.location, currentClassDecl.name);
                thisType.declaration = currentClassDecl;
                return thisType;
            } else {
                auto thisType = new UserType(expr.location, currentStructDecl.name);
                thisType.declaration = currentStructDecl;
                return thisType;
            }
        }
        
        Symbol symbol = symbolTable.lookupSymbol(expr.name);
        if (!symbol) {
            // Inside a method, check if it's a field of the current struct/class (implicit this)
            if (currentStructDecl) {
                auto field = currentStructDecl.getField(expr.name);
                if (field) {
                    return field.type;
                }
            }
            if (currentClassDecl) {
                // Check class fields (including inherited fields)
                auto field = currentClassDecl.getField(expr.name);
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

        // IFTI: if callee is a template, deduce type args from call args
        if (auto identExpr = cast(IdentifierExpression)expr.function_) {
            auto sym = symbolTable.lookupSymbol(identExpr.name);
            if (sym && sym.kind == SymbolKind.Template) {
                auto tmplDecl = cast(TemplateDecl)sym.declaration;
                if (tmplDecl) {
                    if (auto funcMember = cast(FunctionDecl)tmplDecl.eponymousMember())
                        return checkImplicitTemplateCall(expr, tmplDecl, funcMember);
                }
            }
        }

        // emplace(ptr, args...) — compiler intrinsic
        if (auto identExpr = cast(IdentifierExpression)expr.function_) {
            if (identExpr.name == "emplace") {
                return checkEmplaceCall(expr);
            }
        }

        // Handle struct method calls (obj.method()) or UFCS (obj.func() -> func(obj))
        if (auto memberExpr = cast(MemberExpression)expr.function_) {
            Type objectType = checkExpression(memberExpr.object);
            bool foundMethod = false;

            // Auto-deref: pointer-to-struct method calls (ptr.method())
            if (auto ptrType = cast(PointerType)objectType) {
                objectType = ptrType.pointeeType;
                memberExpr.isAutoDereference = true;
            }

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
                
                // Check for class methods
                if (auto classDecl = cast(ClassDecl)userType.declaration) {
                    auto method = getClassMethod(classDecl, memberExpr.memberName);
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
                
                // Check for interface methods
                if (auto ifaceDecl = cast(InterfaceDecl)userType.declaration) {
                    auto method = getInterfaceMethod(ifaceDecl, memberExpr.memberName);
                    if (method) {
                        foundMethod = true;
                        // Check argument types
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
            
            // Try alias-this forwarding for method calls
            if (!foundMethod) {
                if (auto userType = cast(UserType)objectType) {
                    AggregateDecl aggr;
                    if (auto sd = cast(StructDecl)userType.declaration) aggr = sd;
                    else if (auto cd = cast(ClassDecl)userType.declaration) aggr = cd;
                    if (aggr && aggr.aliasThis.length > 0 && aliasThisDepth <= 10) {
                        aliasThisDepth++;
                        scope(exit) aliasThisDepth--;
                        auto savedObject = memberExpr.object;
                        foreach (aliasName; aggr.aliasThis) {
                            auto aliasField = aggr.getField(aliasName);
                            if (aliasField) {
                                // Tentatively rewrite: obj.method() → obj.aliasName.method()
                                memberExpr.object = new MemberExpression(expr.location, savedObject, aliasName);
                                try {
                                    return checkCallExpression(expr);
                                } catch (TypeError) {
                                    memberExpr.object = savedObject;
                                }
                            }
                        }
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
        
        // Implicit this.method() — bare identifier call inside a method body.
        // If the identifier isn't a known free function or type, check if it's
        // a method on the current struct/class (including inherited methods).
        if (auto identExpr = cast(IdentifierExpression)expr.function_) {
            auto symbol = symbolTable.lookupSymbol(identExpr.name);
            if (symbol is null || (symbol.kind != SymbolKind.Function && symbol.kind != SymbolKind.Type
                    && symbol.kind != SymbolKind.Template)) {
                FunctionDecl method = null;
                if (currentClassDecl)
                    method = getClassMethod(currentClassDecl, identExpr.name);
                else if (currentStructDecl)
                    method = getStructMethod(currentStructDecl, identExpr.name);

                if (method) {
                    // Rewrite: score(args) → this.score(args)
                    auto thisExpr = new IdentifierExpression(identExpr.location, "this");
                    auto memberExpr = new MemberExpression(identExpr.location, thisExpr, identExpr.name);
                    expr.function_ = memberExpr;
                    return checkCallExpression(expr);
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
                    // Try alias-this unwrapping on argument
                    if (!tryAliasThisUnwrap(expr.arguments[i], argType, paramType)) {
                        throw new TypeError(
                            format("Argument %d: expected type '%s', got '%s'",
                                   i + 1, paramType.toString(), argType.toString()),
                            expr.arguments[i].location
                        );
                    }
                }
            }
        }
        
        // Transitive @gc enforcement: calling a @gc function requires @gc on caller
        if (auto identExpr = cast(IdentifierExpression)expr.function_) {
            auto sym = symbolTable.lookupSymbol(identExpr.name);
            if (sym && sym.declaration) {
                if (auto calleeFunc = cast(FunctionDecl)sym.declaration) {
                    if (calleeFunc.gcStrategy !is null) {
                        if (currentFunctionDecl is null || currentFunctionDecl.gcStrategy is null)
                            throw new TypeError(
                                format("calling @gc(%s) function '%s' requires @gc on the caller",
                                       calleeFunc.gcStrategy, calleeFunc.name),
                                expr.location);
                    }
                }
            }
        }

        return functionType.returnType;
    }

    /**
     * Type check template instantiation call: max!int(3, 5)
     */
    Type checkTemplateInstantiation(TemplateInstantiationExpression expr) {
        // Look up the template by name
        auto sym = symbolTable.lookupSymbol(expr.templateName);
        if (!sym || sym.kind != SymbolKind.Template) {
            throw new TypeError(
                format("'%s' is not a template", expr.templateName),
                expr.location
            );
        }
        auto tmplDecl = cast(TemplateDecl)sym.declaration;
        if (!tmplDecl) {
            throw new TypeError(
                format("'%s' is not a template", expr.templateName),
                expr.location
            );
        }

        // Build TemplateArg[] from parsed args, using param kinds to disambiguate
        auto tmplArgs = buildTemplateArgs(tmplDecl, expr.templateArguments,
                                          expr.templateArgExpressions, expr.location);

        // Instantiate (constraint checked inside reparseAndSubstitute via CTFE)
        auto inst = templateInstantiator.instantiate(tmplDecl, tmplArgs);

        // Dispatch based on what the template contains
        if (auto funcInst = cast(FunctionDecl)inst) {
            // Function template instantiation — type-check and validate call args
            if (!funcInst.isTypeChecked) {
                auto saved = symbolTable.saveAndResetScope();
                scope(exit) symbolTable.restoreScope(saved);
                checkFunctionDeclaration(funcInst);
            }

            expr.resolvedInstantiation = funcInst;

            // Check call argument count
            if (expr.callArguments.length != funcInst.parameters.length) {
                throw new TypeError(
                    format("'%s' expects %d arguments, got %d",
                           funcInst.name, funcInst.parameters.length, expr.callArguments.length),
                    expr.location
                );
            }

            // Check call argument types
            for (size_t i = 0; i < expr.callArguments.length; i++) {
                Type argType = checkExpression(expr.callArguments[i]);
                Type paramType = funcInst.parameters[i].type;

                auto compat = checkTypeCompatibility(argType, paramType);
                if (!compat.isCompatible) {
                    throw new TypeError(
                        format("Argument %d: expected type '%s', got '%s'",
                               i + 1, paramType.toString(), argType.toString()),
                        expr.callArguments[i].location
                    );
                }
            }

            return funcInst.returnType;
        }

        if (auto structInst = cast(StructDecl)inst) {
            // Struct template instantiation — register, layout, type-check, then check construction
            if (!structInst.layoutComputed) {
                auto collector = new SymbolCollector(symbolTable);
                collector.collectStructSymbol(structInst);
                checkStructDeclaration(structInst);
            }

            expr.resolvedStructInstantiation = structInst;

            // Create a UserType for the instantiated struct and check construction
            auto userType = new UserType(expr.location, structInst.name);
            userType.declaration = structInst;

            return checkStructConstruction(structInst, userType, expr.callArguments, expr.location);
        }

        throw new TypeError(
            format("'%s' template instantiation is not callable", expr.templateName),
            expr.location
        );
    }

    /**
     * Resolve a UserType with templateArgs (e.g. Pair!(int, int) in type position).
     * Instantiates the template, registers the struct, and sets userType.declaration.
     */
    void resolveTemplateUserType(UserType userType) {
        auto sym = symbolTable.lookupSymbol(userType.name);
        if (!sym || sym.kind != SymbolKind.Template) {
            throw new TypeError(
                format("'%s' is not a template", userType.name),
                userType.location
            );
        }
        auto tmplDecl = cast(TemplateDecl)sym.declaration;
        if (!tmplDecl) {
            throw new TypeError(
                format("'%s' is not a template", userType.name),
                userType.location
            );
        }

        // Build TemplateArg[] from parsed args, using param kinds to disambiguate
        auto tmplArgs = buildTemplateArgs(tmplDecl, userType.templateArgs,
                                          userType.templateArgExprs, userType.location);

        // Constraint checked inside reparseAndSubstitute via CTFE
        auto inst = templateInstantiator.instantiate(tmplDecl, tmplArgs);

        if (auto structInst = cast(StructDecl)inst) {
            // Only register if not already laid out (cached instantiation)
            if (!structInst.layoutComputed) {
                auto collector = new SymbolCollector(symbolTable);
                collector.collectStructSymbol(structInst);
                // Save/restore scope state: checkStructDeclaration type-checks
                // methods which reset nextLocalId, corrupting the caller's IDs.
                auto saved = symbolTable.saveAndResetScope();
                scope(exit) symbolTable.restoreScope(saved);
                checkStructDeclaration(structInst);
            }

            userType.declaration = structInst;
            userType.name = structInst.name;
        } else {
            throw new TypeError(
                format("Template '%s' does not produce a type", userType.name),
                userType.location
            );
        }
    }

    /**
     * Build a TemplateArg[] from parsed type/expression arrays,
     * using template parameter kinds to disambiguate ambiguous identifiers.
     */
    private TemplateArg[] buildTemplateArgs(TemplateDecl tmplDecl, Type[] parsedTypes,
                                            Expression[] parsedExprs, SourceLocation loc) {
        // Count provided args (max of both parallel arrays)
        size_t providedCount = parsedTypes.length;
        if (parsedExprs.length > providedCount)
            providedCount = parsedExprs.length;

        if (providedCount != tmplDecl.templateParams.length) {
            throw new TypeError(
                format("Template '%s' expects %d arguments, got %d",
                       tmplDecl.name, tmplDecl.templateParams.length, providedCount),
                loc
            );
        }

        TemplateArg[] result = new TemplateArg[tmplDecl.templateParams.length];
        foreach (i, param; tmplDecl.templateParams) {
            Type parsedType = (i < parsedTypes.length) ? parsedTypes[i] : null;
            Expression parsedExpr = (parsedExprs && i < parsedExprs.length) ? parsedExprs[i] : null;

            if (param.isValueParam) {
                // Value parameter — need an expression
                Expression valExpr = parsedExpr;
                // If parser only stored it as a type (ambiguous identifier), extract as expression
                if (valExpr is null && parsedType !is null) {
                    if (auto ut = cast(UserType)parsedType) {
                        valExpr = new IdentifierExpression(ut.location, ut.name);
                    }
                }
                if (valExpr is null) {
                    throw new TypeError(
                        format("Template '%s' parameter '%s' expects a value, not a type",
                               tmplDecl.name, param.paramName),
                        loc
                    );
                }
                result[i] = TemplateArg(null, resolveValueArg(valExpr, param.valueType, loc));
            } else {
                // Type parameter — need a type
                Type typeArg = parsedType;
                if (typeArg is null) {
                    throw new TypeError(
                        format("Template '%s' parameter '%s' expects a type, not a value",
                               tmplDecl.name, param.paramName),
                        loc
                    );
                }
                result[i] = TemplateArg(typeArg, null);
            }
        }
        return result;
    }

    /**
     * Resolve a value template argument expression to a compile-time constant.
     * Handles literal expressions directly; for identifiers, looks up manifest constants.
     */
    private Expression resolveValueArg(Expression expr, Type expectedType, SourceLocation loc) {
        if (auto lit = cast(LiteralExpression)expr) {
            // Already a literal — good to go
            return lit;
        }
        if (auto ident = cast(IdentifierExpression)expr) {
            // Try to resolve as a manifest constant
            auto sym = symbolTable.lookupSymbol(ident.name);
            if (sym && sym.isConstant) {
                if (auto manifest = cast(ManifestConstantDecl)sym.declaration) {
                    if (manifest.ctfeComplete) {
                        return LiteralExpression.integer(ident.location, manifest.ctfeValue);
                    }
                }
            }
            throw new TypeError(
                format("'%s' is not a compile-time constant", ident.name),
                ident.location
            );
        }
        throw new TypeError(
            format("Template value argument must be a compile-time constant"),
            loc
        );
    }

    /**
     * IFTI: Implicit Function Template Instantiation.
     * Deduce template type args from call arguments, instantiate, and type-check.
     */
    Type checkImplicitTemplateCall(CallExpression expr, TemplateDecl tmplDecl, FunctionDecl templateFunc) {
        // Type-check each argument to get argTypes
        Type[] argTypes;
        foreach (arg; expr.arguments) {
            argTypes ~= checkExpression(arg);
        }

        // Deduce template type arguments from call arguments
        Type[] deducedTypes = new Type[tmplDecl.templateParams.length];
        foreach (i, param; templateFunc.parameters) {
            if (i >= argTypes.length) break;
            if (auto tpt = cast(TemplateParamType)param.type) {
                // Find which template param this is
                foreach (j, tp; tmplDecl.templateParams) {
                    if (tp.paramName == tpt.paramName) {
                        if (deducedTypes[j] is null) {
                            deducedTypes[j] = argTypes[i];
                        }
                        break;
                    }
                }
            }
        }

        // Verify all template params were deduced
        foreach (i, dt; deducedTypes) {
            if (dt is null) {
                throw new TypeError(
                    format("Cannot deduce template parameter '%s' from call arguments",
                           tmplDecl.templateParams[i].paramName),
                    expr.location
                );
            }
        }

        // Instantiate (constraint checked inside reparseAndSubstitute via CTFE)
        auto inst = cast(FunctionDecl)templateInstantiator.instantiate(tmplDecl, deducedTypes);
        if (!inst)
            throw new TypeError("IFTI: template did not produce a function", expr.location);

        // Type-check the instantiation at module scope
        if (!inst.isTypeChecked) {
            auto saved = symbolTable.saveAndResetScope();
            scope(exit) symbolTable.restoreScope(saved);
            checkFunctionDeclaration(inst);
        }

        expr.resolvedInstantiation = inst;

        // Check call argument count
        if (expr.arguments.length != inst.parameters.length) {
            throw new TypeError(
                format("'%s' expects %d arguments, got %d",
                       inst.name, inst.parameters.length, expr.arguments.length),
                expr.location
            );
        }

        // Check call argument types against instantiation
        for (size_t i = 0; i < expr.arguments.length; i++) {
            Type paramType = inst.parameters[i].type;
            auto compat = checkTypeCompatibility(argTypes[i], paramType);
            if (!compat.isCompatible) {
                throw new TypeError(
                    format("Argument %d: expected type '%s', got '%s'",
                           i + 1, paramType.toString(), argTypes[i].toString()),
                    expr.arguments[i].location
                );
            }
        }

        return inst.returnType;
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
     * Get a method from a class by name, returns null if not found
     */
    FunctionDecl getClassMethod(ClassDecl classDecl, string methodName) {
        // Search up the inheritance hierarchy
        ClassDecl current = classDecl;
        while (current) {
            foreach (member; current.members) {
                if (auto funcDecl = cast(FunctionDecl)member) {
                    if (funcDecl.name == methodName && funcDecl.isMethod) {
                        return funcDecl;
                    }
                }
            }
            current = current.baseClassDecl;
        }
        return null;
    }
    
    /**
     * Get a method from an interface by name
     */
    FunctionDecl getInterfaceMethod(InterfaceDecl ifaceDecl, string methodName) {
        foreach (method; ifaceDecl.methods) {
            if (method.name == methodName) {
                return method;
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

    Type checkEmplaceCall(CallExpression expr) {
        if (expr.arguments.length < 1)
            throw new TypeError("emplace requires at least a pointer argument", expr.location);

        // First arg must be T* (pointer to struct)
        Type ptrArgType = checkExpression(expr.arguments[0]);
        auto ptrType = cast(PointerType)ptrArgType;
        if (!ptrType)
            throw new TypeError(
                format("emplace first argument must be a pointer, got '%s'", ptrArgType.toString()),
                expr.arguments[0].location);

        auto userType = cast(UserType)ptrType.pointeeType;
        if (!userType) {
            userType = cast(UserType)(resolveAliasType(ptrType.pointeeType));
        }
        if (!userType)
            throw new TypeError(
                format("emplace pointer must point to a struct type, got '%s*'", ptrType.pointeeType.toString()),
                expr.arguments[0].location);

        userType.ensureResolved(symbolTable);
        auto structDecl = cast(StructDecl)userType.declaration;
        if (!structDecl)
            throw new TypeError(
                format("emplace pointer must point to a struct type, '%s' is not a struct", userType.name),
                expr.arguments[0].location);

        // Remaining args are field initializers
        Expression[] fieldArgs = expr.arguments[1 .. $];
        if (fieldArgs.length > structDecl.fields.length)
            throw new TypeError(
                format("emplace: struct '%s' has %d fields, got %d initializers",
                       structDecl.name, structDecl.fields.length, fieldArgs.length),
                expr.location);

        // Type-check each field argument
        for (size_t i = 0; i < fieldArgs.length; i++) {
            Type argType = checkExpression(fieldArgs[i]);
            Type fieldType = structDecl.fields[i].type;
            if (fieldType) {
                auto compat = checkTypeCompatibility(argType, fieldType);
                if (!compat.isCompatible)
                    throw new TypeError(
                        format("emplace: cannot initialize field '%s' of type '%s' with value of type '%s'",
                               structDecl.fields[i].name, fieldType.toString(), argType.toString()),
                        fieldArgs[i].location);
            }
        }

        // Store resolution for codegen
        expr.resolvedEmplaceStruct = structDecl;

        // Return type: same pointer type (for chaining)
        return ptrType;
    }

    Type checkNewExpression(NewExpression expr) {
        // Enforce @gc(heap) on enclosing function
        if (currentFunctionDecl is null || currentFunctionDecl.gcStrategy is null)
            throw new TypeError("'new' requires @gc on the enclosing function", expr.location);

        // Resolve the allocated type
        Type allocType = resolveAliasType(expr.allocatedType);
        resolveUserType(allocType);

        // V1: must be a struct
        auto userType = cast(UserType)allocType;
        if (!userType)
            throw new TypeError(
                format("'new' requires a struct type, got '%s'", allocType.toString()),
                expr.location);

        userType.ensureResolved(symbolTable);
        auto structDecl = cast(StructDecl)userType.declaration;
        if (!structDecl)
            throw new TypeError(
                format("'new' requires a struct type, '%s' is not a struct", userType.name),
                expr.location);

        // Validate field arguments (same pattern as emplace)
        if (expr.arguments.length > structDecl.fields.length)
            throw new TypeError(
                format("'new %s': struct has %d fields, got %d arguments",
                       structDecl.name, structDecl.fields.length, expr.arguments.length),
                expr.location);

        for (size_t i = 0; i < expr.arguments.length; i++) {
            Type argType = checkExpression(expr.arguments[i]);
            Type fieldType = structDecl.fields[i].type;
            if (fieldType) {
                auto compat = checkTypeCompatibility(argType, fieldType);
                if (!compat.isCompatible)
                    throw new TypeError(
                        format("'new %s': cannot initialize field '%s' of type '%s' with '%s'",
                               structDecl.name, structDecl.fields[i].name,
                               fieldType.toString(), argType.toString()),
                        expr.arguments[i].location);
            }
        }

        // Store resolution for codegen
        expr.resolvedStruct = structDecl;

        // Return PointerType
        return new PointerType(expr.location, allocType);
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
                if (!expr.operand.hasLValue()) {
                    throw new TypeError(
                        format("Increment/decrement requires an lvalue, not '%s'",
                               expr.operand.toString()),
                        expr.location);
                }
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
        
        // Array slicing returns a dynamic array type (a view)
        if (auto arrType = cast(ArrayType)arrayType) {
            if (arrType.isStaticArray) {
                // static array slice → dynamic array (view into static data)
                return new ArrayType(expr.location, arrType.elementType);
            }
            return arrType;  // dynamic slice → same type
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

    Type checkTraitsExpression(TraitsExpression expr) {
        auto loc = expr.location;

        // Resolve UserType via symbol table before evaluating
        if (expr.typeArguments.length > 0 && expr.typeArguments[0] !is null) {
            if (auto ut = cast(UserType)expr.typeArguments[0]) {
                try { ut.ensureResolved(symbolTable); } catch (Exception) {}
            }
        }

        // Special case: compiles needs type checker (try-check expression)
        if (expr.traitName == "compiles") {
            expr.boolResult = checkCompilesTrait(expr);
            expr.evaluated = true;
            return new BasicType(loc, BasicType.Kind.Bool);
        }

        // Special case: identifier returns string type
        if (expr.traitName == "identifier") {
            expr.evaluate();
            auto charType = new BasicType(loc, BasicType.Kind.Char);
            return new ArrayType(loc, charType);
        }

        // Special case: allMembers returns string[] type
        if (expr.traitName == "allMembers") {
            expr.evaluate();
            auto charType = new BasicType(loc, BasicType.Kind.Char);
            auto stringType = new ArrayType(loc, charType);
            return new ArrayType(loc, stringType);
        }

        expr.evaluate();
        return new BasicType(loc, BasicType.Kind.Bool);
    }

    /**
     * Synthesize field-wise equality for struct comparison.
     * Generates: left.f1 == right.f1 && left.f2 == right.f2 && ...
     * For != operator, wraps in LogicalNot.
     */
    private Expression synthesizeStructEquals(BinaryExpression expr, StructDecl structDecl) {
        auto loc = expr.location;
        Expression synthesized = null;

        foreach (field; structDecl.fields) {
            auto leftField = new MemberExpression(loc, expr.left, field.name);
            auto rightField = new MemberExpression(loc, expr.right, field.name);
            auto fieldCmp = new BinaryExpression(loc, leftField, BinaryExpression.Operator.Equal, rightField);
            checkExpression(fieldCmp);  // type-check synthesized comparison
            if (synthesized is null)
                synthesized = fieldCmp;
            else
                synthesized = new BinaryExpression(loc, synthesized, BinaryExpression.Operator.LogicalAnd, fieldCmp);
        }

        // No fields: always equal
        if (synthesized is null)
            synthesized = LiteralExpression.integer(loc, 1);

        if (expr.operator == BinaryExpression.Operator.NotEqual)
            synthesized = new UnaryExpression(loc, UnaryExpression.Operator.LogicalNot, synthesized);

        return synthesized;
    }

    private bool checkCompilesTrait(TraitsExpression expr) {
        if (expr.arguments.length == 0 || expr.arguments[0] is null) return false;
        try {
            checkExpression(expr.arguments[0]);
            return true;
        } catch (TypeError) {
            return false;
        } catch (Exception) {
            return false;
        }
    }

    Type checkIsExpression(IsExpression expr) {
        // Resolve UserType via symbol table
        if (auto ut = cast(UserType)expr.checkedType) {
            try { ut.ensureResolved(symbolTable); } catch (Exception) {}
        }
        if (expr.specType !is null) {
            if (auto ut = cast(UserType)expr.specType) {
                try { ut.ensureResolved(symbolTable); } catch (Exception) {}
            }
        }

        if (expr.operator is null) {
            // is(T) — type validity: true if type resolved successfully
            expr.boolResult = expr.checkedType !is null;
        } else if (expr.specKeyword !is null) {
            // is(T == struct), is(T == class), etc.
            expr.boolResult = checkTypeCategory(expr.checkedType, expr.specKeyword);
        } else if (expr.operator == "==") {
            // is(T == int) — exact type match
            expr.boolResult = typesEqual(expr.checkedType, expr.specType);
        } else if (expr.operator == ":") {
            // is(T : int) — implicit conversion
            expr.boolResult = checkTypeCompatibility(expr.checkedType, expr.specType).isCompatible;
        }

        expr.evaluated = true;
        return new BasicType(expr.location, BasicType.Kind.Bool);
    }

    private bool checkTypeCategory(Type type, string category) {
        if (type is null) return false;
        switch (category) {
            case "struct":    return type.asStruct() !is null;
            case "class":     return type.asClass() !is null;
            case "interface": return type.asInterface() !is null;
            case "enum":      return false; // future: type.asEnum()
            default:          return false;
        }
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

        // Auto-deref: if objectType is PointerType, unwrap to pointee type
        if (auto ptrType = cast(PointerType)objectType) {
            objectType = ptrType.pointeeType;
            expr.isAutoDereference = true;
        }

        // Handle struct field access
        if (auto userType = cast(UserType)objectType) {
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
                // Try alias-this forwarding
                if (auto rewritten = tryAliasThisFieldForward(expr, structDecl)) {
                    return rewritten;
                }
                throw new TypeError(
                    format("Struct '%s' has no field '%s'", userType.name, expr.memberName),
                    expr.location);
            }

            // Handle class field access (same as struct, but layout includes vtable_ptr)
            if (auto classDecl = cast(ClassDecl)userType.declaration) {
                auto field = classDecl.getField(expr.memberName);
                if (field) {
                    return field.type;
                }
                // Try alias-this forwarding
                if (auto rewritten = tryAliasThisFieldForward(expr, classDecl)) {
                    return rewritten;
                }
                throw new TypeError(
                    format("Class '%s' has no field '%s'", userType.name, expr.memberName),
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
    
    /// Resolve transparent type aliases. If type is a UserType that names an alias,
    /// return the alias's target type (following chains). Otherwise return the type unchanged.
    private Type resolveAliasType(Type type) {
        if (auto ut = cast(UserType)type) {
            auto target = symbolTable.lookupAlias(ut.name);
            if (target) {
                return resolveAliasType(target);  // follow chains
            }
        }
        return type;
    }

    /// Ensure a UserType has its declaration linked (template instantiation or plain lookup).
    private void resolveUserType(Type type) {
        if (auto ut = cast(UserType)type) {
            if (ut.templateArgs.length > 0) {
                resolveTemplateUserType(ut);
            } else if (!ut.declaration) {
                auto sym = symbolTable.lookupSymbol(ut.name);
                if (sym && sym.kind == SymbolKind.Type) {
                    ut.declaration = sym.declaration;
                }
            }
        }
    }

    /// Try alias-this forwarding for member field access.
    /// Rewrites expr.object to insert the alias-this indirection.
    /// Returns the resolved type if successful, null otherwise.
    private Type tryAliasThisFieldForward(MemberExpression expr, AggregateDecl aggr) {
        if (aliasThisDepth > 10) return null;  // cycle detection
        aliasThisDepth++;
        scope(exit) aliasThisDepth--;

        auto savedObject = expr.object;
        foreach (aliasName; aggr.aliasThis) {
            auto aliasField = aggr.getField(aliasName);
            if (aliasField) {
                // Tentatively rewrite: obj.member → obj.aliasName.member
                expr.object = new MemberExpression(expr.location, savedObject, aliasName);
                try {
                    return checkMemberExpression(expr);
                } catch (TypeError) {
                    // This alias path didn't work, try the next one
                    expr.object = savedObject;
                }
            }
        }
        return null;
    }

    /// Try to unwrap an expression via alias-this to make it compatible with targetType.
    /// Rewrites expr in-place by wrapping it in a MemberExpression.
    /// Returns the new type if successful, null otherwise.
    private Type tryAliasThisUnwrap(ref Expression expr, Type fromType, Type targetType) {
        auto aggr = getAliasThisAggregate(fromType);
        if (!aggr) return null;
        if (aliasThisDepth > 10) return null;
        aliasThisDepth++;
        scope(exit) aliasThisDepth--;

        // Best-match: prefer exact over promotion
        string bestAlias;
        Type bestType;
        bool bestExact = false;
        int matchCount = 0;

        foreach (aliasName; aggr.aliasThis) {
            auto aliasField = aggr.getField(aliasName);
            if (aliasField) {
                auto compat = checkTypeCompatibility(aliasField.type, targetType);
                if (compat.isCompatible) {
                    bool exact = !compat.needsConversion;
                    if (matchCount == 0 || (exact && !bestExact)) {
                        bestAlias = aliasName;
                        bestType = aliasField.type;
                        bestExact = exact;
                    }
                    matchCount++;
                }
            }
        }

        if (matchCount == 1 || bestExact) {
            expr = new MemberExpression(expr.location, expr, bestAlias);
            return bestType;
        }
        return null;
    }

    Type checkCastExpression(CastExpression expr) {
        Type sourceType = checkExpression(expr.expression);  // Verify source expression is valid

        // Resolve transparent type aliases in cast target
        expr.targetType = resolveAliasType(expr.targetType);

        // Resolve UserType declarations if not already resolved
        if (auto userType = cast(UserType)expr.targetType) {
            if (!userType.declaration) {
                auto typeSymbol = symbolTable.lookupSymbol(userType.name);
                if (typeSymbol && typeSymbol.kind == SymbolKind.Type) {
                    userType.declaration = typeSymbol.declaration;
                }
            }
            
            // Check for class→interface cast
            if (auto targetIface = cast(InterfaceDecl)userType.declaration) {
                // Source must be a class that implements this interface
                if (auto sourceUserType = cast(UserType)sourceType) {
                    // Resolve source declaration if needed
                    if (!sourceUserType.declaration) {
                        auto srcSymbol = symbolTable.lookupSymbol(sourceUserType.name);
                        if (srcSymbol && srcSymbol.kind == SymbolKind.Type) {
                            sourceUserType.declaration = srcSymbol.declaration;
                        }
                    }
                    if (auto sourceClass = cast(ClassDecl)sourceUserType.declaration) {
                        // Verify class implements the interface
                        if (classImplementsInterface(sourceClass, targetIface)) {
                            // Annotate the cast for codegen
                            expr.sourceClassDecl = sourceClass;
                            expr.targetInterfaceDecl = targetIface;
                        } else {
                            throw new TypeError(
                                format("Class '%s' does not implement interface '%s'",
                                       sourceClass.name, targetIface.name),
                                expr.location);
                        }
                    }
                }
            }
        }
        
        return expr.targetType;  // Cast always produces target type
    }
    
    Type checkAssignmentExpression(AssignmentExpression expr) {
        Type leftType = checkExpression(expr.left);
        Type rightType = checkExpression(expr.right);

        // Compound shift assignments — lower to checked call but keep operator
        if (expr.operator == AssignmentExpression.Operator.ShiftLeftAssign ||
            expr.operator == AssignmentExpression.Operator.ShiftRightAssign) {
            string funcName;
            if (expr.operator == AssignmentExpression.Operator.ShiftLeftAssign)
                funcName = "opShiftLeft";
            else
                funcName = "opShiftRight";
            auto callExpr = new CallExpression(expr.location,
                new IdentifierExpression(expr.location, funcName),
                [expr.left, expr.right]);
            checkCallExpression(callExpr);
            expr.loweredCall = callExpr;
            return leftType;
        }

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
            // Try alias-this unwrapping on right-hand side
            if (!tryAliasThisUnwrap(expr.right, rightType, leftType)) {
                throw new TypeError(
                    format("Cannot assign type '%s' to '%s'",
                           rightType.toString(), leftType.toString()),
                    expr.location
                );
            }
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
        from = resolveAliasType(from.resolve());
        to = resolveAliasType(to.resolve());
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
        
        // Class inheritance compatibility (upcasting)
        auto fromUser = cast(UserType)from;
        auto toUser = cast(UserType)to;
        
        if (fromUser && toUser) {
            // Ensure declarations are resolved
            if (!fromUser.declaration) {
                auto sym = symbolTable.lookupSymbol(fromUser.name);
                if (sym && sym.kind == SymbolKind.Type) {
                    fromUser.declaration = sym.declaration;
                }
            }
            if (!toUser.declaration) {
                auto sym = symbolTable.lookupSymbol(toUser.name);
                if (sym && sym.kind == SymbolKind.Type) {
                    toUser.declaration = sym.declaration;
                }
            }
            
            auto fromClass = cast(ClassDecl)fromUser.declaration;
            auto toClass = cast(ClassDecl)toUser.declaration;
            auto toInterface = cast(InterfaceDecl)toUser.declaration;
            
            if (fromClass && toClass) {
                // Check if fromClass is-a toClass (fromClass inherits from toClass)
                ClassDecl current = fromClass;
                while (current) {
                    if (current is toClass) {
                        return TypeCompatibility.compatible();
                    }
                    current = current.baseClassDecl;
                }
            }
            
            // Class to interface: check if class implements the interface
            if (fromClass && toInterface) {
                if (classImplementsInterface(fromClass, toInterface)) {
                    return TypeCompatibility.compatible();
                }
            }
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

    /// Get the AggregateDecl for a type if it has alias-this members.
    private AggregateDecl getAliasThisAggregate(Type t) {
        if (auto ut = cast(UserType)t) {
            if (auto sd = cast(StructDecl)ut.declaration) {
                if (sd.aliasThis.length > 0) return sd;
            }
            if (auto cd = cast(ClassDecl)ut.declaration) {
                if (cd.aliasThis.length > 0) return cd;
            }
        }
        return null;
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
        left = left.resolve();
        right = right.resolve();
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
        a = a.resolve();
        b = b.resolve();
        if (a is b) return true;
        // Simplified equality check - in a full implementation this would be more sophisticated
        return a.toString() == b.toString();
    }
    
    bool isArithmeticType(Type type) {
        if (!type) return false;
        type = type.resolve();
        auto basic = cast(BasicType)type;
        return basic && (isIntegerType(basic) || isFloatingType(basic));
    }
    
    bool isNumericType(Type type) {
        return isArithmeticType(type);
    }
    
    bool isIntegralType(Type type) {
        if (!type) return false;
        type = type.resolve();
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
        type = type.resolve();
        auto basic = cast(BasicType)type;
        if (basic) {
            return basic.kind == BasicType.Kind.Bool;
        }
        return false;
    }
    
    bool isVoidType(Type type) {
        if (!type) return false;
        type = type.resolve();
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
        } else if (literal.value.type == typeid(char)) {
            // Char literal
            return new BasicType(literal.location, BasicType.Kind.Char);
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