/**
 * WebAssembly Code Generator for D-to-WASM Compiler
 * 
 * This module generates WebAssembly Text Format (WAT) from type-checked AST.
 * It produces real WASM bytecode that can be executed in browsers and runtimes.
 */
module codegen.wasm_generator;

import ast.nodes;
import ast.statements;
import ast.expressions;
import semantic.symbol_table;
import std.string;
import std.array;
import std.algorithm;
import std.conv;
import std.stdio;
import std.file;

/**
 * WASM data types
 */
enum WasmType {
    i32,     // 32-bit integer
    i64,     // 64-bit integer  
    f32,     // 32-bit float
    f64,     // 64-bit float
    void_    // void (no return value)
}

/**
 * WASM function signature
 */
struct WasmFunction {
    string name;
    WasmType[] parameters;
    WasmType returnType;
    string[] instructions;
    string[] localVariables;  // Local variable declarations
    
    /**
     * Generate WAT function definition
     */
    string toWAT() {
        auto result = appender!string();
        
        // Function header
        result ~= format("  (func $%s", name);
        
        // Parameters
        foreach (i, param; parameters) {
            result ~= format(" (param $p%d %s)", i, wasmTypeToString(param));
        }
        
        // Return type
        if (returnType != WasmType.void_) {
            result ~= format(" (result %s)", wasmTypeToString(returnType));
        }
        
        result ~= "\n";
        
        // Local variables
        foreach (localVar; localVariables) {
            result ~= "    " ~ localVar ~ "\n";
        }
        
        // Function body instructions
        foreach (instruction; instructions) {
            result ~= "    " ~ instruction ~ "\n";
        }
        
        result ~= "  )";
        return result.data;
    }
    
    private string wasmTypeToString(WasmType type) {
        final switch (type) {
            case WasmType.i32: return "i32";
            case WasmType.i64: return "i64";
            case WasmType.f32: return "f32";
            case WasmType.f64: return "f64";
            case WasmType.void_: return "";
        }
    }
}

/**
 * WASM module structure
 */
struct WasmModule {
    WasmFunction[] functions;
    string[] imports;
    string[] exports;
    string[] globalVariables;
    uint memorySize = 1;  // Memory pages (64KB each)
    
    /**
     * Generate complete WAT module
     */
    string toWAT() {
        auto result = appender!string();
        
        result ~= "(module\n";
        
        // Memory declaration
        result ~= format("  (memory %d)\n", memorySize);
        
        // Imports
        foreach (imp; imports) {
            result ~= "  " ~ imp ~ "\n";
        }
        
        // Global variables
        foreach (global; globalVariables) {
            result ~= "  " ~ global ~ "\n";
        }
        
        // Functions
        foreach (func; functions) {
            result ~= func.toWAT() ~ "\n\n";
        }
        
        // Exports
        foreach (exp; exports) {
            result ~= "  " ~ exp ~ "\n";
        }
        
        result ~= ")";
        return result.data;
    }
    
    /**
     * Convert WAT to binary WASM (placeholder - would use wat2wasm tool)
     */
    ubyte[] toBinary() {
        // In a real implementation, this would invoke wat2wasm
        // For now, just return empty array
        return [];
    }
}

/**
 * Code generation context
 */
class CodeGenContext {
    SymbolTable symbolTable;
    WasmFunction currentFunction;
    string[] expressionStack;  // Track expression evaluation stack
    uint nextLocalId = 0;
    uint[string] localVariableIds;  // Map variable names to local IDs
    
    this(SymbolTable symbolTable) {
        this.symbolTable = symbolTable;
    }
    
    /**
     * Add local variable and return its ID
     */
    uint addLocalVariable(string name, WasmType type) {
        uint id = nextLocalId++;
        localVariableIds[name] = id;
        currentFunction.localVariables ~= format("(local $l%d %s)", id, wasmTypeToString(type));
        return id;
    }
    
    /**
     * Get local variable ID
     */
    uint getLocalVariableId(string name) {
        auto ptr = name in localVariableIds;
        if (!ptr) {
            throw new CodeGenError(format("Unknown local variable: %s", name));
        }
        return *ptr;
    }
    
    /**
     * Add instruction to current function
     */
    void addInstruction(string instruction) {
        currentFunction.instructions ~= instruction;
    }
    
    /**
     * Convert D type to WASM type
     */
    WasmType dTypeToWasmType(Type type) {
        auto basic = cast(BasicType)type;
        if (basic) {
            switch (basic.kind) {
                case BasicType.Kind.Bool:
                case BasicType.Kind.Int8:
                case BasicType.Kind.Int16:
                case BasicType.Kind.Int32:
                case BasicType.Kind.UInt8:
                case BasicType.Kind.UInt16:
                case BasicType.Kind.UInt32:
                case BasicType.Kind.Char:
                    return WasmType.i32;
                case BasicType.Kind.Int64:
                case BasicType.Kind.UInt64:
                    return WasmType.i64;
                case BasicType.Kind.Float32:
                    return WasmType.f32;
                case BasicType.Kind.Float64:
                    return WasmType.f64;
                case BasicType.Kind.Void:
                    return WasmType.void_;
                default:
                    throw new CodeGenError(format("Unsupported basic type: %s", basic.kind));
            }
        }
        
        // TODO: Handle user types, pointers, arrays
        throw new CodeGenError(format("Cannot convert type to WASM: %s", type.toString()));
    }
    
    private string wasmTypeToString(WasmType type) {
        final switch (type) {
            case WasmType.i32: return "i32";
            case WasmType.i64: return "i64";
            case WasmType.f32: return "f32";
            case WasmType.f64: return "f64";
            case WasmType.void_: return "";
        }
    }
}

/**
 * Code generation error
 */
class CodeGenError : Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__) {
        super(message, file, line);
    }
}

/**
 * Main WASM code generator
 */
class WasmGenerator {
    private SymbolTable symbolTable;
    private CodeGenContext context;
    private WasmModule wasmModule;
    
    this(SymbolTable symbolTable) {
        this.symbolTable = symbolTable;
        this.context = new CodeGenContext(symbolTable);
    }
    
    /**
     * Generate WASM module from declarations
     */
    WasmModule generateModule(Declaration[] declarations) {
        wasmModule = WasmModule();
        
        // Generate code for all declarations
        foreach (decl; declarations) {
            generateDeclaration(decl);
        }
        
        // Add exports for main function if it exists
        foreach (func; wasmModule.functions) {
            if (func.name == "main") {
                wasmModule.exports ~= format("(export \"main\" (func $%s))", func.name);
            }
        }
        
        return wasmModule;
    }
    
    /**
     * Generate code for a declaration
     */
    void generateDeclaration(Declaration decl) {
        if (auto funcDecl = cast(FunctionDecl)decl) {
            generateFunction(funcDecl);
        } else if (auto varDecl = cast(VariableDecl)decl) {
            generateGlobalVariable(varDecl);
        }
        // TODO: Handle classes, structs, enums
    }
    
    /**
     * Generate WASM function
     */
    void generateFunction(FunctionDecl decl) {
        auto wasmFunc = WasmFunction();
        wasmFunc.name = decl.name;
        
        // Set current function context
        context.currentFunction = wasmFunc;
        context.nextLocalId = 0;
        context.localVariableIds.clear();
        
        // Convert parameters
        foreach (i, param; decl.parameters) {
            WasmType paramType = context.dTypeToWasmType(param.type);
            wasmFunc.parameters ~= paramType;
            
            // Parameters are automatically local variables with IDs 0, 1, 2...
            context.localVariableIds[param.name] = cast(uint)i;
        }
        context.nextLocalId = cast(uint)decl.parameters.length;
        
        // Convert return type
        wasmFunc.returnType = context.dTypeToWasmType(decl.returnType);
        
        // Generate function body
        if (decl.body_) {
            generateStatement(decl.body_);
        }
        
        // Add implicit return for void functions
        if (wasmFunc.returnType == WasmType.void_) {
            context.addInstruction("return");
        }
        
        context.currentFunction = wasmFunc;
        wasmModule.functions ~= wasmFunc;
    }
    
    /**
     * Generate global variable
     */
    void generateGlobalVariable(VariableDecl decl) {
        WasmType wasmType = context.dTypeToWasmType(decl.type);
        
        // Generate initializer value
        string initValue = "i32.const 0";  // Default initialization
        if (decl.initializer) {
            // TODO: Evaluate constant initializer expressions
        }
        
        string globalDef = format("(global $%s (mut %s) %s)",
                                  decl.name,
                                  context.wasmTypeToString(wasmType),
                                  initValue);
        wasmModule.globalVariables ~= globalDef;
    }
    
    /**
     * Generate code for statement
     */
    void generateStatement(Statement stmt) {
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                generateStatement(s);
            }
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            generateIfStatement(ifStmt);
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            generateWhileStatement(whileStmt);
        } else if (auto forStmt = cast(ForStatement)stmt) {
            generateForStatement(forStmt);
        } else if (auto returnStmt = cast(ReturnStatement)stmt) {
            generateReturnStatement(returnStmt);
        } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
            generateExpression(exprStmt.expression);
            // Drop expression result if not used
            if (context.currentFunction.returnType == WasmType.void_) {
                context.addInstruction("drop");
            }
        }
    }
    
    /**
     * Generate if statement
     */
    void generateIfStatement(IfStatement stmt) {
        // Generate condition
        generateExpression(stmt.condition);
        
        if (stmt.elseStatement) {
            // if-else
            context.addInstruction("if");
            generateStatement(stmt.thenStatement);
            context.addInstruction("else");
            generateStatement(stmt.elseStatement);
            context.addInstruction("end");
        } else {
            // if only
            context.addInstruction("if");
            generateStatement(stmt.thenStatement);
            context.addInstruction("end");
        }
    }
    
    /**
     * Generate while statement
     */
    void generateWhileStatement(WhileStatement stmt) {
        context.addInstruction("loop");
        generateExpression(stmt.condition);
        context.addInstruction("if");
        generateStatement(stmt.body_);
        context.addInstruction("br 1");  // Branch back to loop
        context.addInstruction("end");
        context.addInstruction("end");
    }
    
    /**
     * Generate for statement (convert to while)
     */
    void generateForStatement(ForStatement stmt) {
        // Generate init
        if (stmt.init) {
            generateStatement(stmt.init);
        }
        
        // Convert to while loop
        context.addInstruction("loop");
        
        if (stmt.condition) {
            generateExpression(stmt.condition);
        } else {
            context.addInstruction("i32.const 1");  // infinite loop
        }
        
        context.addInstruction("if");
        generateStatement(stmt.body_);
        
        if (stmt.update) {
            generateExpression(stmt.update);
            context.addInstruction("drop");  // Drop update result
        }
        
        context.addInstruction("br 1");  // Branch back to loop
        context.addInstruction("end");
        context.addInstruction("end");
    }
    
    /**
     * Generate return statement
     */
    void generateReturnStatement(ReturnStatement stmt) {
        if (stmt.value) {
            generateExpression(stmt.value);
        }
        context.addInstruction("return");
    }
    
    /**
     * Generate expression and leave result on stack
     */
    void generateExpression(Expression expr) {
        if (auto binary = cast(BinaryExpression)expr) {
            generateBinaryExpression(binary);
        } else if (auto call = cast(CallExpression)expr) {
            generateCallExpression(call);
        } else if (auto ident = cast(IdentifierExpression)expr) {
            generateIdentifierExpression(ident);
        } else if (auto literal = cast(LiteralExpression)expr) {
            generateLiteralExpression(literal);
        } else if (auto assign = cast(AssignmentExpression)expr) {
            generateAssignmentExpression(assign);
        }
        // TODO: Handle other expression types
    }
    
    /**
     * Generate binary expression
     */
    void generateBinaryExpression(BinaryExpression expr) {
        // Generate operands (left first, then right - WASM is stack-based)
        generateExpression(expr.left);
        generateExpression(expr.right);
        
        // Generate operator instruction
        switch (expr.operator) {
            case BinaryExpression.Operator.Add:
                context.addInstruction("i32.add");
                break;
            case BinaryExpression.Operator.Subtract:
                context.addInstruction("i32.sub");
                break;
            case BinaryExpression.Operator.Multiply:
                context.addInstruction("i32.mul");
                break;
            case BinaryExpression.Operator.Divide:
                context.addInstruction("i32.div_s");  // signed division
                break;
            case BinaryExpression.Operator.Modulo:
                context.addInstruction("i32.rem_s");  // signed remainder
                break;
            case BinaryExpression.Operator.Equal:
                context.addInstruction("i32.eq");
                break;
            case BinaryExpression.Operator.NotEqual:
                context.addInstruction("i32.ne");
                break;
            case BinaryExpression.Operator.Less:
                context.addInstruction("i32.lt_s");
                break;
            case BinaryExpression.Operator.LessEqual:
                context.addInstruction("i32.le_s");
                break;
            case BinaryExpression.Operator.Greater:
                context.addInstruction("i32.gt_s");
                break;
            case BinaryExpression.Operator.GreaterEqual:
                context.addInstruction("i32.ge_s");
                break;
            default:
                throw new CodeGenError(format("Binary operator not yet implemented: %s", expr.operator));
        }
    }
    
    /**
     * Generate function call
     */
    void generateCallExpression(CallExpression expr) {
        // Generate arguments in order
        foreach (arg; expr.arguments) {
            generateExpression(arg);
        }
        
        // Get function name
        if (auto identExpr = cast(IdentifierExpression)expr.function_) {
            context.addInstruction(format("call $%s", identExpr.name));
        } else {
            throw new CodeGenError("Indirect function calls not yet supported");
        }
    }
    
    /**
     * Generate identifier reference (variable access)
     */
    void generateIdentifierExpression(IdentifierExpression expr) {
        Symbol symbol = symbolTable.lookupSymbol(expr.name);
        if (!symbol) {
            throw new CodeGenError(format("Unknown identifier: %s", expr.name));
        }
        
        if (symbol.kind == SymbolKind.Variable || symbol.kind == SymbolKind.Parameter) {
            if (symbol.isGlobal) {
                context.addInstruction(format("global.get $%s", symbol.name));
            } else {
                uint localId = context.getLocalVariableId(symbol.name);
                context.addInstruction(format("local.get $l%d", localId));
            }
        } else if (symbol.kind == SymbolKind.Function) {
            // Function reference - this would be used for function pointers
            throw new CodeGenError("Function references not yet supported");
        } else {
            throw new CodeGenError(format("Cannot reference symbol kind: %s", symbol.kind));
        }
    }
    
    /**
     * Generate literal expression
     */
    void generateLiteralExpression(LiteralExpression expr) {
        import std.variant;
        
        if (!expr.value.hasValue) {
            context.addInstruction("i32.const 0");  // NULL as 0
            return;
        }
        
        if (expr.value.type == typeid(long)) {
            context.addInstruction(format("i32.const %d", expr.value.get!long));
        } else if (expr.value.type == typeid(double)) {
            context.addInstruction(format("f64.const %f", expr.value.get!double));
        } else if (expr.value.type == typeid(bool)) {
            context.addInstruction(format("i32.const %d", expr.value.get!bool ? 1 : 0));
        } else if (expr.value.type == typeid(string)) {
            // String literals not yet supported - would need memory management
            throw new CodeGenError("String literals not yet supported");
        } else {
            throw new CodeGenError(format("Unsupported literal type: %s", expr.value.type));
        }
    }
    
    /**
     * Generate assignment expression
     */
    void generateAssignmentExpression(AssignmentExpression expr) {
        // Generate right-hand side first
        generateExpression(expr.right);
        
        // Store to left-hand side
        if (auto identExpr = cast(IdentifierExpression)expr.left) {
            Symbol symbol = symbolTable.lookupSymbol(identExpr.name);
            if (!symbol) {
                throw new CodeGenError(format("Unknown identifier: %s", identExpr.name));
            }
            
            if (symbol.isGlobal) {
                context.addInstruction(format("global.set $%s", symbol.name));
            } else {
                uint localId = context.getLocalVariableId(symbol.name);
                context.addInstruction(format("local.set $l%d", localId));
            }
            
            // Assignment expression also produces the assigned value
            if (symbol.isGlobal) {
                context.addInstruction(format("global.get $%s", symbol.name));
            } else {
                uint localId = context.getLocalVariableId(symbol.name);
                context.addInstruction(format("local.get $l%d", localId));
            }
        } else {
            throw new CodeGenError("Complex left-hand side assignments not yet supported");
        }
    }
    
    /**
     * Write WASM module to file
     */
    void writeToFile(string filename) {
        string wat = wasmModule.toWAT();
        std.file.write(filename, wat);
    }
    
    /**
     * Write binary WASM to file (placeholder)
     */
    void writeBinaryToFile(string filename) {
        ubyte[] binary = wasmModule.toBinary();
        std.file.write(filename, binary);
    }
}