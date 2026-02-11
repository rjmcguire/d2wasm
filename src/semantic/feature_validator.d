/**
 * Feature Validator for D-to-WASM Compiler
 * 
 * This module implements the first semantic analysis pass that validates
 * that only supported D language features are used. It provides helpful
 * error messages for unsupported constructs.
 * 
 * Unsupported features:
 * - Templates and generics
 * - Garbage collection (new operator, class instances)
 * - Module system (import statements)
 * - Threading and concurrency
 * - String mixins
 * - CTFE (in initial version)
 * - Complex attributes beyond @safe/@pure
 */
module semantic.feature_validator;

import ast.nodes;
import ast.statements;
import ast.expressions;
import std.string;
import std.algorithm;

/**
 * Feature validation error with helpful suggestions
 */
class FeatureValidationError : Exception {
    SourceLocation location;
    string feature;
    string suggestion;
    
    this(string message, SourceLocation location, string feature = "", 
         string suggestion = "", string file = __FILE__, size_t line = __LINE__) {
        this.location = location;
        this.feature = feature;
        this.suggestion = suggestion;
        
        string fullMessage = format("%s at %s", message, location.toString());
        if (feature.length) {
            fullMessage ~= format("\n  Unsupported feature: %s", feature);
        }
        if (suggestion.length) {
            fullMessage ~= format("\n  Suggestion: %s", suggestion);
        }
        
        super(fullMessage, file, line);
    }
}

/**
 * Feature validator that traverses the AST and checks for unsupported constructs
 */
class FeatureValidator {
    private bool inClassContext = false;
    private bool inInterfaceContext = false;
    private string currentFunctionName = "";
    
    /**
     * Validate a list of declarations (typically a source file)
     */
    void validateSourceFile(Declaration[] declarations) {
        foreach (decl; declarations) {
            validateDeclaration(decl);
        }
    }
    
    /**
     * Validate a single declaration
     */
    void validateDeclaration(Declaration decl) {
        if (auto func = cast(FunctionDecl) decl) {
            validateFunctionDecl(func);
        } else if (auto cls = cast(ClassDecl) decl) {
            validateClassDecl(cls);
        } else if (auto struct_ = cast(StructDecl) decl) {
            validateStructDecl(struct_);
        } else if (auto iface = cast(InterfaceDecl) decl) {
            validateInterfaceDecl(iface);
        } else if (auto var = cast(VariableDecl) decl) {
            validateVariableDecl(var);
        } else if (auto enum_ = cast(EnumDecl) decl) {
            validateEnumDecl(enum_);
        }
    }
    
    /**
     * Validate function declaration
     */
    void validateFunctionDecl(FunctionDecl node) {
        currentFunctionName = node.name;
        
        // Check for unsupported function features
        validateFunctionAttributes(node);
        validateFunctionSignature(node);
        
        // Validate return type and parameters
        if (node.returnType) {
            validateType(node.returnType);
        }
        
        foreach (param; node.parameters) {
            validateType(param.type);
            if (param.defaultValue) {
                validateExpression(param.defaultValue);
            }
        }
        
        // Validate function body
        if (node.body_) {
            validateStatement(node.body_);
        }
        
        currentFunctionName = "";
    }
    
    /**
     * Validate class declaration
     */
    void validateClassDecl(ClassDecl node) {
        inClassContext = true;
        
        // Validate class features
        validateClassDeclaration(node);
        
        // Check base class and interfaces
        if (node.baseClass) {
            validateType(node.baseClass);
        }
        foreach (iface; node.interfaces) {
            validateType(iface);
        }
        
        // Validate members
        foreach (member; node.members) {
            validateDeclaration(member);
        }
        
        inClassContext = false;
    }
    
    /**
     * Validate struct declaration
     */
    void validateStructDecl(StructDecl node) {
        // Structs are fully supported
        foreach (member; node.members) {
            validateDeclaration(member);
        }
    }
    
    /**
     * Validate interface declaration
     */
    void validateInterfaceDecl(InterfaceDecl node) {
        inInterfaceContext = true;
        
        // Check parent interfaces
        foreach (parent; node.parentInterfaces) {
            validateType(parent);
        }
        
        // Validate interface methods
        foreach (method; node.methods) {
            validateFunctionDecl(method);
        }
        
        inInterfaceContext = false;
    }
    
    /**
     * Validate variable declaration
     */
    void validateVariableDecl(VariableDecl node) {
        // Check for GC allocation in variable declarations
        validateType(node.type);
        
        if (node.initializer) {
            validateExpression(node.initializer);
        }
    }
    
    /**
     * Validate enum declaration
     */
    void validateEnumDecl(EnumDecl node) {
        // Enums are fully supported
        validateType(node.baseType);
        
        foreach (member; node.members) {
            if (member.value) {
                validateExpression(member.value);
            }
        }
    }
    
    /**
     * Validate a type
     */
    void validateType(Type type) {
        if (auto basicType = cast(BasicType) type) {
            // All basic types are supported
        } else if (auto arrayType = cast(ArrayType) type) {
            validateType(arrayType.elementType);
            if (arrayType.arraySize) {
                validateExpression(arrayType.arraySize);
            }
        } else if (auto pointerType = cast(PointerType) type) {
            validateType(pointerType.pointeeType);
        } else if (auto funcType = cast(FunctionType) type) {
            validateType(funcType.returnType);
            foreach (param; funcType.parameterTypes) {
                validateType(param);
            }
        } else if (auto userType = cast(UserType) type) {
            // Check for template instantiation syntax
            if (userType.name.canFind("!") || userType.name.canFind("<")) {
                throw new FeatureValidationError(
                    "Template instantiation is not supported",
                    userType.location,
                    "Templates and generics",
                    "Use function overloading instead of templates"
                );
            }
        }
    }
    
    /**
     * Validate a statement
     */
    void validateStatement(Statement stmt) {
        if (auto compound = cast(CompoundStatement) stmt) {
            foreach (s; compound.statements) {
                validateStatement(s);
            }
        } else if (auto ifStmt = cast(IfStatement) stmt) {
            validateExpression(ifStmt.condition);
            validateStatement(ifStmt.thenStatement);
            if (ifStmt.elseStatement) {
                validateStatement(ifStmt.elseStatement);
            }
        } else if (auto whileStmt = cast(WhileStatement) stmt) {
            validateExpression(whileStmt.condition);
            validateStatement(whileStmt.body_);
        } else if (auto forStmt = cast(ForStatement) stmt) {
            if (forStmt.init) {
                validateStatement(forStmt.init);
            }
            if (forStmt.condition) {
                validateExpression(forStmt.condition);
            }
            if (forStmt.update) {
                validateExpression(forStmt.update);
            }
            validateStatement(forStmt.body_);
        } else if (auto returnStmt = cast(ReturnStatement) stmt) {
            if (returnStmt.value) {
                validateExpression(returnStmt.value);
            }
        } else if (auto exprStmt = cast(ExpressionStatement) stmt) {
            validateExpression(exprStmt.expression);
        }
    }
    
    /**
     * Validate an expression
     */
    void validateExpression(Expression expr) {
        if (auto binExpr = cast(BinaryExpression) expr) {
            validateExpression(binExpr.left);
            validateExpression(binExpr.right);
        } else if (auto unaryExpr = cast(UnaryExpression) expr) {
            validateExpression(unaryExpr.operand);
        } else if (auto callExpr = cast(CallExpression) expr) {
            // Check for GC allocation calls
            validateFunctionCall(callExpr);
            validateExpression(callExpr.function_);
            foreach (arg; callExpr.arguments) {
                validateExpression(arg);
            }
        } else if (auto indexExpr = cast(IndexExpression) expr) {
            validateExpression(indexExpr.array);
            validateExpression(indexExpr.index);
        } else if (auto memberExpr = cast(MemberExpression) expr) {
            validateExpression(memberExpr.object);
        } else if (auto identExpr = cast(IdentifierExpression) expr) {
            // Check for forbidden identifiers
            validateIdentifier(identExpr);
        } else if (auto castExpr = cast(CastExpression) expr) {
            // Validate cast target type
            validateType(castExpr.targetType);
            validateExpression(castExpr.expression);
        } else if (auto assignExpr = cast(AssignmentExpression) expr) {
            validateExpression(assignExpr.left);
            validateExpression(assignExpr.right);
        } else if (auto traits = cast(TraitsExpression) expr) {
            foreach (arg; traits.arguments) {
                if (arg !is null) validateExpression(arg);
            }
        }
        // LiteralExpression is always valid
    }
    
    // ===== VALIDATION HELPERS =====
    
    /**
     * Validate function attributes for unsupported features
     */
    private void validateFunctionAttributes(FunctionDecl node) {
        // Attributes are now stored in Declaration.attrs (DeclAttrs bitfield).
        // All recognized attributes are supported — no validation needed.
    }
    
    /**
     * Validate function signature for templates
     */
    private void validateFunctionSignature(FunctionDecl node) {
        // Check for template syntax in function name
        if (node.name.canFind("!") || node.name.canFind("<")) {
            throw new FeatureValidationError(
                "Template functions are not supported",
                node.location,
                "Function templates",
                "Use function overloading with different parameter types instead"
            );
        }
    }
    
    /**
     * Validate class declaration for unsupported features
     */
    private void validateClassDeclaration(ClassDecl node) {
        // Check for template syntax in class name
        if (node.name.canFind("!") || node.name.canFind("<")) {
            throw new FeatureValidationError(
                "Template classes are not supported",
                node.location,
                "Class templates",
                "Use concrete types and composition instead of generic classes"
            );
        }
        
        // Check for multiple inheritance (only single inheritance allowed)
        if (node.baseClass && node.interfaces.length > 0) {
            // This is actually allowed - single inheritance + interfaces
        }
        
        // TODO: Check for GC-allocated class instances in members
    }
    
    /**
     * Validate function calls for GC allocation
     */
    private void validateFunctionCall(CallExpression node) {
        // Check if this is a 'new' expression (which would be parsed as a call)
        if (auto identExpr = cast(IdentifierExpression) node.function_) {
            if (identExpr.name == "new") {
                throw new FeatureValidationError(
                    "The 'new' operator is not supported - no garbage collection",
                    node.location,
                    "GC allocation",
                    "Use stack allocation, malloc(), or pre-allocated arrays instead"
                );
            }
            
            // Check for other GC-related functions
            string[] gcFunctions = ["delete", "gc_malloc", "gc_free"];
            if (gcFunctions.canFind(identExpr.name)) {
                throw new FeatureValidationError(
                    format("Function '%s' is not supported", identExpr.name),
                    node.location,
                    "GC operations",
                    "Use manual memory management with malloc/free"
                );
            }
        }
    }
    
    /**
     * Validate identifiers for forbidden names
     */
    private void validateIdentifier(IdentifierExpression node) {
        string[] forbiddenNames = [
            // Module system
            "import", "module", "export", "package",
            
            // Threading
            "thread", "spawn", "shared", "synchronized", "atomic",
            "__gshared", "Tid", "send", "receive",
            
            // GC related
            "delete", "destroy", "gc", "GC",
            
            // String mixins
            "mixin", "StringOf",
            
            // Other complex features
            "typeid", "TypeInfo", "Object", "toString"
        ];
        
        if (forbiddenNames.canFind(node.name)) {
            throw new FeatureValidationError(
                format("Identifier '%s' refers to an unsupported feature", node.name),
                node.location,
                getFeatureCategory(node.name),
                getAlternativeSuggestion(node.name)
            );
        }
    }
    
    /**
     * Get the feature category for a forbidden identifier
     */
    private string getFeatureCategory(string identifier) {
        if (["import", "module", "export", "package"].canFind(identifier)) {
            return "Module system";
        }
        if (["thread", "spawn", "shared", "synchronized", "atomic", "__gshared", "Tid", "send", "receive"].canFind(identifier)) {
            return "Threading and concurrency";
        }
        if (["delete", "destroy", "gc", "GC"].canFind(identifier)) {
            return "Garbage collection";
        }
        if (["mixin", "StringOf"].canFind(identifier)) {
            return "String mixins and CTFE";
        }
        if (["typeid", "TypeInfo", "Object", "toString"].canFind(identifier)) {
            return "Runtime type information";
        }
        return "Advanced feature";
    }
    
    /**
     * Get alternative suggestion for forbidden identifier
     */
    private string getAlternativeSuggestion(string identifier) {
        switch (identifier) {
            case "import":
                return "Use all code in a single file - modules are not supported";
            case "new":
                return "Use stack allocation or malloc() for dynamic memory";
            case "delete":
                return "Use free() to deallocate malloc'd memory";
            case "thread", "spawn":
                return "Use single-threaded design - threading is not supported";
            case "shared", "synchronized":
                return "Remove shared data - single-threaded model only";
            case "mixin":
                return "Use regular functions instead of string mixins";
            case "Object", "toString":
                return "Avoid base Object class - use concrete types";
            default:
                return "This feature is not available in the D subset";
        }
    }
}