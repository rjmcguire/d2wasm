/**
 * Symbol Table for D-to-WASM Compiler
 * 
 * This module provides symbol resolution and scope management.
 * It tracks variables, functions, types, and their visibility across scopes.
 */
module semantic.symbol_table;

import ast.nodes;
import ast.statements;
import ast.expressions;
import std.string;
import std.array;
import std.algorithm;
import std.conv;
import std.stdio;

/**
 * Symbol kinds
 */
enum SymbolKind {
    Variable,
    Function,
    Type,
    Parameter,
    Field
}

/**
 * Symbol entry in the symbol table
 */
class Symbol {
    string name;
    SymbolKind kind;
    Type type;
    Declaration declaration;  // AST node that declares this symbol
    SourceLocation location;
    bool isGlobal;
    bool isConstant;  // True for manifest constants (enum X = ...)
    
    this(string name, SymbolKind kind, Type type, Declaration decl, SourceLocation location, bool isGlobal = false) {
        this.name = name;
        this.kind = kind;
        this.type = type;
        this.declaration = decl;
        this.location = location;
        this.isGlobal = isGlobal;
    }
    
    override string toString() {
        string typeStr = type ? type.toString() : "<unknown>";
        return format("%s %s: %s", kind, name, typeStr);
    }
}

/**
 * Symbol scope for managing symbol visibility
 */
class Scope {
    Scope parent;
    Symbol[string] symbols;
    string name;  // For debugging
    
    this(Scope parent = null, string name = "anonymous") {
        this.parent = parent;
        this.name = name;
    }
    
    /**
     * Add symbol to this scope
     */
    void addSymbol(Symbol symbol) {
        if (symbol.name in symbols) {
            throw new SemanticError(
                format("Symbol '%s' is already defined in scope '%s'", symbol.name, name),
                symbol.location
            );
        }
        symbols[symbol.name] = symbol;
    }
    
    /**
     * Look up symbol in this scope only
     */
    Symbol lookupLocal(string name) {
        auto ptr = name in symbols;
        return ptr ? *ptr : null;
    }
    
    /**
     * Look up symbol in this scope and parent scopes
     */
    Symbol lookup(string name) {
        auto local = lookupLocal(name);
        if (local) {
            return local;
        }
        
        if (parent) {
            return parent.lookup(name);
        }
        
        return null;
    }
    
    /**
     * Get all symbols in this scope
     */
    Symbol[] getAllSymbols() {
        return symbols.values;
    }
    
    /**
     * Check if this is a global scope
     */
    bool isGlobal() {
        return parent is null;
    }
}

/**
 * Semantic analysis error
 */
class SemanticError : Exception {
    SourceLocation location;
    
    this(string message, SourceLocation location, string file = __FILE__, size_t line = __LINE__) {
        this.location = location;
        super(format("%s at %s", message, location.toString()), file, line);
    }
}

/**
 * Symbol table manager
 */
class SymbolTable {
    private Scope globalScope;
    private Scope currentScope;
    private Scope[] scopeStack;
    
    this() {
        globalScope = new Scope(null, "global");
        currentScope = globalScope;
    }
    
    /**
     * Enter a new scope
     */
    void enterScope(string name = "block") {
        scopeStack ~= currentScope;
        currentScope = new Scope(currentScope, name);
    }
    
    /**
     * Exit current scope
     */
    void exitScope() {
        if (scopeStack.length == 0) {
            throw new SemanticError("Cannot exit global scope", SourceLocation());
        }
        
        currentScope = scopeStack[$-1];
        scopeStack = scopeStack[0..$-1];
    }
    
    /**
     * Add symbol to current scope
     */
    void addSymbol(Symbol symbol) {
        currentScope.addSymbol(symbol);
    }
    
    /**
     * Look up symbol starting from current scope
     */
    Symbol lookupSymbol(string name) {
        return currentScope.lookup(name);
    }
    
    /**
     * Look up symbol in global scope only
     */
    Symbol lookupGlobalSymbol(string name) {
        return globalScope.lookupLocal(name);
    }
    
    /**
     * Get current scope
     */
    Scope getCurrentScope() {
        return currentScope;
    }
    
    /**
     * Get global scope
     */
    Scope getGlobalScope() {
        return globalScope;
    }
    
    /**
     * Check if we're in global scope
     */
    bool inGlobalScope() {
        return currentScope == globalScope;
    }
    
    /**
     * Add built-in symbols (basic types, functions)
     */
    void addBuiltinSymbols() {
        auto loc = SourceLocation("<builtin>", 1, 1, 0, 0);
        
        // Basic types
        addBuiltinType("void", BasicType.Kind.Void, loc);
        addBuiltinType("bool", BasicType.Kind.Bool, loc);
        addBuiltinType("byte", BasicType.Kind.Int8, loc);
        addBuiltinType("short", BasicType.Kind.Int16, loc);
        addBuiltinType("int", BasicType.Kind.Int32, loc);
        addBuiltinType("long", BasicType.Kind.Int64, loc);
        addBuiltinType("ubyte", BasicType.Kind.UInt8, loc);
        addBuiltinType("ushort", BasicType.Kind.UInt16, loc);
        addBuiltinType("uint", BasicType.Kind.UInt32, loc);
        addBuiltinType("ulong", BasicType.Kind.UInt64, loc);
        addBuiltinType("float", BasicType.Kind.Float32, loc);
        addBuiltinType("double", BasicType.Kind.Float64, loc);
        addBuiltinType("char", BasicType.Kind.Char, loc);
        
        // Builtin functions
        addBuiltinFunction("writeln", loc);
        
        // CTFE-specific builtins
        addBuiltinFunction("__writeln", loc);  // CTFE output during compilation
    }
    
    /**
     * Helper to add built-in type
     */
    private void addBuiltinType(string name, BasicType.Kind kind, SourceLocation loc) {
        auto type = new BasicType(loc, kind);
        auto symbol = new Symbol(name, SymbolKind.Type, type, null, loc, true);
        globalScope.addSymbol(symbol);
    }
    
    /**
     * Helper to add built-in function
     */
    private void addBuiltinFunction(string name, SourceLocation loc) {
        // Create a function type for writeln - it's variadic but we'll simplify it
        // Parameters: variadic (accepts any number of arguments)
        // Return type: void
        auto returnType = new BasicType(loc, BasicType.Kind.Void);
        
        // For now, create a simple function type that can accept any arguments
        // In a complete implementation, this would be more sophisticated
        Type[] paramTypes = []; // Empty parameter list - writeln is variadic
        auto funcType = new FunctionType(loc, returnType, paramTypes);
        auto symbol = new Symbol(name, SymbolKind.Function, funcType, null, loc, true);
        globalScope.addSymbol(symbol);
    }
    
    /**
     * Debug: Print symbol table contents
     */
    void debugPrint() {
        writeln("=== Symbol Table ===");
        debugPrintScope(globalScope, 0);
    }
    
    private void debugPrintScope(Scope scope_, int depth) {
        string indent = replicate("  ", depth);
        writeln(format("%sScope: %s", indent, scope_.name));
        
        foreach (symbol; scope_.symbols.values) {
            writeln(format("%s  %s", indent, symbol.toString()));
        }
        
        // Note: We don't recurse into child scopes here since we don't track them
        // This is a simplified implementation focused on current scope traversal
    }
}

/**
 * Symbol collector visitor - first pass to collect all symbols
 */
class SymbolCollector {
    private SymbolTable symbolTable;
    
    this(SymbolTable symbolTable) {
        this.symbolTable = symbolTable;
    }
    
    /**
     * Collect symbols from declaration list
     */
    void collectSymbols(Declaration[] declarations) {
        foreach (decl; declarations) {
            collectSymbol(decl);
        }
    }
    
    /**
     * Collect symbol from single declaration
     */
    void collectSymbol(Declaration decl) {
        if (auto funcDecl = cast(FunctionDecl)decl) {
            collectFunctionSymbol(funcDecl);
        } else if (auto classDecl = cast(ClassDecl)decl) {
            collectClassSymbol(classDecl);
        } else if (auto structDecl = cast(StructDecl)decl) {
            collectStructSymbol(structDecl);
        } else if (auto varDecl = cast(VariableDecl)decl) {
            collectVariableSymbol(varDecl);
        } else if (auto enumDecl = cast(EnumDecl)decl) {
            collectEnumSymbol(enumDecl);
        } else if (auto manifestDecl = cast(ManifestConstantDecl)decl) {
            collectManifestConstant(manifestDecl);
        }
    }
    
    private void collectFunctionSymbol(FunctionDecl decl) {
        auto symbol = new Symbol(
            decl.name,
            SymbolKind.Function,
            new FunctionType(decl.location, decl.returnType, getFunctionParameterTypes(decl)),
            decl,
            decl.location,
            symbolTable.inGlobalScope()
        );
        symbolTable.addSymbol(symbol);
    }
    
    private void collectClassSymbol(ClassDecl decl) {
        auto symbol = new Symbol(
            decl.name,
            SymbolKind.Type,
            new UserType(decl.location, decl.name),
            decl,
            decl.location,
            symbolTable.inGlobalScope()
        );
        symbolTable.addSymbol(symbol);
    }
    
    private void collectStructSymbol(StructDecl decl) {
        auto symbol = new Symbol(
            decl.name,
            SymbolKind.Type,
            new UserType(decl.location, decl.name),
            decl,
            decl.location,
            symbolTable.inGlobalScope()
        );
        symbolTable.addSymbol(symbol);
    }
    
    private void collectVariableSymbol(VariableDecl decl) {
        auto symbol = new Symbol(
            decl.name,
            SymbolKind.Variable,
            decl.type,
            decl,
            decl.location,
            symbolTable.inGlobalScope()
        );
        symbolTable.addSymbol(symbol);
    }
    
    private void collectEnumSymbol(EnumDecl decl) {
        auto symbol = new Symbol(
            decl.name,
            SymbolKind.Type,
            new UserType(decl.location, decl.name),
            decl,
            decl.location,
            symbolTable.inGlobalScope()
        );
        symbolTable.addSymbol(symbol);
    }
    
    private void collectManifestConstant(ManifestConstantDecl decl) {
        // Use the inferred type if CTFE has already evaluated it, 
        // otherwise default to Int32 (will be updated later if needed)
        Type symbolType;
        if (decl.ctfeComplete && decl.inferredType !is null) {
            symbolType = decl.inferredType;
        } else {
            symbolType = new BasicType(decl.location, BasicType.Kind.Int32);
        }
        
        auto symbol = new Symbol(
            decl.name,
            SymbolKind.Variable,  // Manifest constants are like compile-time variables
            symbolType,
            decl,
            decl.location,
            symbolTable.inGlobalScope()
        );
        symbol.isConstant = true;  // Mark as constant
        symbolTable.addSymbol(symbol);
    }
    
    private Type[] getFunctionParameterTypes(FunctionDecl decl) {
        Type[] types;
        foreach (param; decl.parameters) {
            types ~= param.type;
        }
        return types;
    }
}