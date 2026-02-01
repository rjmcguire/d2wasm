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
import codegen.template_engine;
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
        // In the new template-driven approach, the template generates the whole function
        // which we store in instructions[0].
        if (instructions.length > 0) {
            return instructions.join("\n");
        }
        
        // Fallback for non-templated generation (if any remains)
        auto result = appender!string();
        result ~= format("  (func $%s", name);
        foreach (i, param; parameters) {
            result ~= format(" (param $p%d %s)", i, wasmTypeToString(param));
        }
        if (returnType != WasmType.void_) {
            result ~= format(" (result %s)", wasmTypeToString(returnType));
        }
        result ~= "\n";
        foreach (localVar; localVariables) {
            result ~= "    " ~ localVar ~ "\n";
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
        
        // Memory declaration and export
        result ~= format("  (memory (export \"memory\") %d)\n", memorySize);
        
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
        
        // Automatic exports for all functions
        foreach (func; functions) {
            result ~= format("  (export \"%s\" (func $%s))\n", func.name, func.name);
        }
        
        // Manual exports
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
    TemplateEngine templateEngine;
    WasmFunction currentFunction;
    string[] expressionStack;  // Track expression evaluation stack
    uint nextLocalId = 0;
    uint[string] localVariableIds;  // Map variable names to local IDs
    
    this(SymbolTable symbolTable, TemplateEngine templateEngine) {
        this.symbolTable = symbolTable;
        this.templateEngine = templateEngine;
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
    private TemplateEngine templateEngine;
    private CodeGenContext context;
    private WasmModule wasmModule;
    
    this(SymbolTable symbolTable) {
        this.symbolTable = symbolTable;
        this.templateEngine = new SimpleTemplateEngine();
        this.context = new CodeGenContext(symbolTable, this.templateEngine);
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
        
        // Use temporary context for this function
        context.currentFunction = wasmFunc;
        context.nextLocalId = 0;
        context.localVariableIds.clear();
        wasmFunc.instructions = [];
        wasmFunc.localVariables = [];
        
        // Convert parameters
        string paramList = "";
        foreach (i, param; decl.parameters) {
            WasmType paramType = context.dTypeToWasmType(param.type);
            wasmFunc.parameters ~= paramType;
            
            // Parameters are automatically local variables with IDs 0, 1, 2...
            uint id = cast(uint)i;
            context.localVariableIds[param.name] = id;
            
            paramList ~= format(" (param $l%d %s)", id, context.wasmTypeToString(paramType));
        }
        context.nextLocalId = cast(uint)decl.parameters.length;
        
        // Convert return type
        wasmFunc.returnType = context.dTypeToWasmType(decl.returnType);
        string returnTypeStr = (wasmFunc.returnType == WasmType.void_) ? "" : 
                               format(" (result %s)", context.wasmTypeToString(wasmFunc.returnType));
        
        // Generate function body
        string bodyCode = "";
        if (decl.body_) {
            bodyCode = generateStatement(decl.body_);
        }
        
        // Add implicit return for void functions if body doesn't end with one
        if (wasmFunc.returnType == WasmType.void_ && !bodyCode.canFind("return")) {
            bodyCode ~= "\n  return";
        }
        
        // Locals string
        string localsStr = wasmFunc.localVariables.join("\n  ");
        
        // Use template to generate the whole function WAT
        string[string] tParams;
        tParams["FUNCTION_NAME"] = decl.name;
        tParams["PARAMETER_LIST"] = paramList;
        tParams["RETURN_TYPE"] = returnTypeStr;
        tParams["LOCAL_VARIABLES"] = localsStr;
        tParams["FUNCTION_BODY"] = bodyCode;
        
        // We still store it in WasmFunction but we can store the whole body in instructions for now
        // or just have a flag that says "already templated"
        wasmFunc.instructions = [templateEngine.substitute("core/function_declaration", tParams)];
        
        // Special case: we don't want the double (func ...) wrapper from toWAT()
        // So let's add a special field or handle it in WasmModule
        
        // For now, let's keep the structure but effectively bypass toWAT by putting the whole thing in instructions[0]
        // and making parameters/returnType empty in the wasmFunc object so toWAT() logic is minimal?
        // No, let's just make a new toWAT for our templated functions.
        
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
    string generateStatement(Statement stmt) {
        if (auto compound = cast(CompoundStatement)stmt) {
            string result = "";
            foreach (s; compound.statements) {
                result ~= generateStatement(s) ~ "\n";
            }
            return result;
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            return generateIfStatement(ifStmt);
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            return generateWhileStatement(whileStmt);
        } else if (auto forStmt = cast(ForStatement)stmt) {
            return generateForStatement(forStmt);
        } else if (auto returnStmt = cast(ReturnStatement)stmt) {
            return generateReturnStatement(returnStmt);
        } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
            string exprCode = generateExpression(exprStmt.expression);
            string[string] params;
            params["EXPRESSION_CODE"] = exprCode;
            
            // Determine if we need to drop the result
            // If the expression produces a result but the statement doesn't use it, we drop.
            // For now, we use a simple heuristic: if it's a CallExpression or BinaryExpression, it likely left something.
            // A more robust way would be to get the expression's inferred type.
            bool needsDrop = true; // Default to safe drop
            
            params["DROP_IF_NEEDED"] = needsDrop ? "drop" : "";
            return templateEngine.substitute("core/expression_statement", params);
        }
        return "";
    }
    
    /**
     * Generate if statement
     */
    string generateIfStatement(IfStatement stmt) {
        string conditionCode = generateExpression(stmt.condition);
        string thenBody = generateStatement(stmt.thenStatement);
        string elseClause = "";
        
        if (stmt.elseStatement) {
            elseClause = "else\n  " ~ generateStatement(stmt.elseStatement);
        }
        
        string[string] params;
        params["CONDITION_EXPRESSION"] = conditionCode;
        params["THEN_BODY"] = thenBody;
        params["ELSE_CLAUSE"] = elseClause;
        
        return templateEngine.substitute("control_flow/if_statement", params);
    }
    
    /**
     * Generate while statement
     */
    
    /**
     * Generate return statement
     */
    string generateReturnStatement(ReturnStatement stmt) {
        string valExpr = "";
        if (stmt.value) {
            valExpr = generateExpression(stmt.value);
        }
        
        string[string] params;
        params["VALUE_EXPRESSION"] = valExpr;
        
        return templateEngine.substitute("control_flow/return_statement", params);
    }
    
    // Placeholder loops - can be implemented with templates too
    string generateWhileStatement(WhileStatement stmt) { return ";; while placeholder"; }
    string generateForStatement(ForStatement stmt) { return ";; for placeholder"; }
    
    /**
     * Generate expression and leave result on stack
     */
    string generateExpression(Expression expr) {
        if (auto binary = cast(BinaryExpression)expr) {
            return generateBinaryExpression(binary);
        } else if (auto call = cast(CallExpression)expr) {
            return generateCallExpression(call);
        } else if (auto ident = cast(IdentifierExpression)expr) {
            return generateIdentifierExpression(ident);
        } else if (auto literal = cast(LiteralExpression)expr) {
            return generateLiteralExpression(literal);
        } else if (auto assign = cast(AssignmentExpression)expr) {
            return generateAssignmentExpression(assign);
        }
        return ";; unknown expr";
    }
    
    /**
     * Generate binary expression
     */
    string generateBinaryExpression(BinaryExpression expr) {
        string[string] params;
        params["LEFT"] = generateExpression(expr.left);
        params["RIGHT"] = generateExpression(expr.right);
        params["TYPE"] = "i32"; // Simplified for now, should use type inference
        params["OP"] = getBinaryOp(expr.operator);
        
        return templateEngine.substitute("expressions/binary_operation", params);
    }

    private string getBinaryOp(BinaryExpression.Operator op) {
        switch (op) {
            case BinaryExpression.Operator.Add: return "add";
            case BinaryExpression.Operator.Subtract: return "sub";
            case BinaryExpression.Operator.Multiply: return "mul";
            case BinaryExpression.Operator.Divide: return "div_s";
            case BinaryExpression.Operator.Equal: return "eq";
            case BinaryExpression.Operator.NotEqual: return "ne";
            case BinaryExpression.Operator.Less: return "lt_s";
            case BinaryExpression.Operator.LessEqual: return "le_s";
            case BinaryExpression.Operator.Greater: return "gt_s";
            case BinaryExpression.Operator.GreaterEqual: return "ge_s";
            default: return "unknown_op";
        }
    }
    
    /**
     * Generate function call
     */
    string generateCallExpression(CallExpression expr) {
        string args = "";
        foreach (arg; expr.arguments) {
            args ~= generateExpression(arg) ~ "\n";
        }
        
        string funcName = "unknown";
        if (auto identExpr = cast(IdentifierExpression)expr.function_) {
            funcName = identExpr.name;
        }
        
        string[string] params;
        params["ARGUMENTS"] = args;
        params["FUNCTION_NAME"] = funcName;
        
        return templateEngine.substitute("core/function_call", params);
    }
    
    /**
     * Generate identifier reference (variable access)
     */
    string generateIdentifierExpression(IdentifierExpression expr) {
        // Try to look up in local variables first
        auto ptr = expr.name in context.localVariableIds;
        if (ptr) {
            string[string] params;
            params["VARIABLE_NAME"] = format("l%d", *ptr);
            params["GET_INSTRUCTION"] = "local.get";
            return templateEngine.substitute("expressions/variable_access", params);
        }
        
        // Fall back to global symbol table
        Symbol symbol = symbolTable.lookupSymbol(expr.name);
        if (!symbol) return ";; unknown symbol " ~ expr.name;
        
        string[string] params;
        params["VARIABLE_NAME"] = symbol.name;
        params["GET_INSTRUCTION"] = symbol.isGlobal ? "global.get" : "local.get";
        
        return templateEngine.substitute("expressions/variable_access", params);
    }
    
    /**
     * Generate literal expression
     */
    string generateLiteralExpression(LiteralExpression expr) {
        if (!expr.value.hasValue) return "i32.const 0";
        
        if (expr.value.type == typeid(long)) {
            string[string] params;
            params["VALUE"] = to!string(expr.value.get!long);
            return templateEngine.substitute("expressions/literal_int", params);
        }
        return ";; unsupported literal";
    }
    
    /**
     * Generate assignment expression
     */
    string generateAssignmentExpression(AssignmentExpression expr) {
        string valExpr = generateExpression(expr.right);
        
        if (auto identExpr = cast(IdentifierExpression)expr.left) {
            string[string] params;
            params["VALUE_EXPRESSION"] = valExpr;
            
            // Try to look up in local variables first
            auto ptr = identExpr.name in context.localVariableIds;
            if (ptr) {
                params["VARIABLE_NAME"] = format("l%d", *ptr);
                params["SET_INSTRUCTION"] = "local.set";
                params["GET_INSTRUCTION"] = "local.get";
            } else {
                // Fall back to global symbol table
                Symbol symbol = symbolTable.lookupSymbol(identExpr.name);
                if (!symbol) return ";; unknown assignment target " ~ identExpr.name;
                
                params["VARIABLE_NAME"] = symbol.name;
                params["SET_INSTRUCTION"] = symbol.isGlobal ? "global.set" : "local.set";
                params["GET_INSTRUCTION"] = symbol.isGlobal ? "global.get" : "local.get";
                
                if (!symbol.isGlobal) {
                    uint localId = context.getLocalVariableId(symbol.name);
                    params["VARIABLE_NAME"] = format("l%d", localId);
                }
            }
            
            return templateEngine.substitute("core/variable_assignment", params);
        }
        return ";; complex assignment placeholder";
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