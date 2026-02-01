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
    string[] dataEntries;  // Data section entries
    uint memorySize = 1;  // Memory pages (64KB each)
    
    /**
     * Generate complete WAT module
     */
    string toWAT() {
        auto result = appender!string();
        
        result ~= "(module\n";
        
        // Imports must come first
        foreach (imp; imports) {
            result ~= "  " ~ imp ~ "\n";
        }
        
        // Memory declaration and export
        result ~= format("  (memory (export \"memory\") %d)\n", memorySize);
        
        // Data section entries
        foreach (data; dataEntries) {
            result ~= "  " ~ data ~ "\n";
        }
        
        // Global variables
        foreach (global; globalVariables) {
            result ~= "  " ~ global ~ "\n";
        }
        
        // Functions
        foreach (func; functions) {
            result ~= func.toWAT() ~ "\n\n";
        }
        
        // Automatic exports for all functions (skip internal WASI helpers)
        foreach (func; functions) {
            if (func.name != "write_str" && func.name != "_start") {
                result ~= format("  (export \"%s\" (func $%s))\n", func.name, func.name);
            }
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
    uint nextLoopId = 0;
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
        
        // Add WASI imports for console output
        addWasiImports();
        
        // Add WASI helper functions
        addWasiHelpers();
        
        // Generate code for all declarations
        foreach (decl; declarations) {
            generateDeclaration(decl);
        }
        
        // Add WASI _start entry point if main function exists
        addWasiEntryPoint();
        
        // Transfer pending data entries to module
        wasmModule.dataEntries = pendingDataEntries;
        
        return wasmModule;
    }
    
    /**
     * Add WASI imports to the module
     */
    private void addWasiImports() {
        wasmModule.imports ~= "(import \"wasi_snapshot_preview1\" \"fd_write\" (func $fd_write (param i32 i32 i32 i32) (result i32)))";
    }
    
    /**
     * Add WASI helper functions for console output
     */
    private void addWasiHelpers() {
        // Add string data section at the end of module generation
        // For now, we'll add a generic write_str function
        auto writeStrFunc = WasmFunction();
        writeStrFunc.name = "write_str";
        writeStrFunc.parameters = [WasmType.i32, WasmType.i32]; // offset, length
        writeStrFunc.returnType = WasmType.void_;
        
        // Generate WASI fd_write helper function
        string wasiHelper = `  (func $write_str (param $offset i32) (param $len i32)
    ;; Setup iovec at memory[0]: [string_ptr, string_len]
    (i32.store (i32.const 0) (local.get $offset))
    (i32.store (i32.const 4) (local.get $len))
    
    ;; fd_write(stdout=1, iovec=0, iovec_count=1, bytes_written=8)
    (call $fd_write
      (i32.const 1)   ;; stdout
      (i32.const 0)   ;; iovec pointer
      (i32.const 1)   ;; number of iovecs
      (i32.const 8))  ;; bytes written output
    drop
  )`;
        
        writeStrFunc.instructions = [wasiHelper];
        wasmModule.functions ~= writeStrFunc;
    }
    
    /**
     * Add WASI _start entry point if main function exists
     */
    private void addWasiEntryPoint() {
        // Check if we have a main function
        bool hasMain = false;
        foreach (func; wasmModule.functions) {
            if (func.name == "main") {
                hasMain = true;
                break;
            }
        }
        
        if (hasMain) {
            auto startFunc = WasmFunction();
            startFunc.name = "_start";
            startFunc.parameters = [];
            startFunc.returnType = WasmType.void_;
            startFunc.instructions = [`  (func $_start
    (call $main)
    drop
  )`];
            
            wasmModule.functions ~= startFunc;
            
            // Export _start instead of main for WASI compatibility
            wasmModule.exports ~= `(export "_start" (func $_start))`;
        }
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
            bool needsDrop = false; // Default to no drop
            
            if (auto callExpr = cast(CallExpression)exprStmt.expression) {
                string funcName = "unknown";
                if (auto identExpr = cast(IdentifierExpression)callExpr.function_) {
                    funcName = identExpr.name;
                }
                
                // writeln() and other void functions don't leave values on the stack
                if (funcName == "writeln") {
                    needsDrop = false;
                } else {
                    // For other function calls, we may need to drop if they return values
                    // For now, assume they return values
                    needsDrop = true;
                }
            } else if (auto binaryExpr = cast(BinaryExpression)exprStmt.expression) {
                // Binary expressions typically leave a value
                needsDrop = true;
            }
            
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
        string elseBody = "";
        
        if (stmt.elseStatement) {
            elseBody = generateStatement(stmt.elseStatement);
            elseClause = "else\n  " ~ elseBody;
        }
        
        string[string] params;
        params["CONDITION_EXPRESSION"] = conditionCode;
        params["THEN_BODY"] = thenBody;
        params["ELSE_CLAUSE"] = elseClause;
        
        string result = templateEngine.substitute("control_flow/if_statement", params);
        
        // If both branches contain return statements, the code after 'end' is unreachable.
        // We need to add 'unreachable' to satisfy WASM type validation for functions
        // that expect a return value.
        bool thenReturns = branchContainsReturn(stmt.thenStatement);
        bool elseReturns = stmt.elseStatement !is null && branchContainsReturn(stmt.elseStatement);
        
        if (thenReturns && elseReturns) {
            result ~= "\nunreachable";
        }
        
        return result;
    }
    
    /**
     * Check if a statement (or its children) contains a return statement.
     * This is used to determine if code after an if/else is reachable.
     */
    private bool branchContainsReturn(Statement stmt) {
        if (auto returnStmt = cast(ReturnStatement)stmt) {
            return true;
        } else if (auto compound = cast(CompoundStatement)stmt) {
            // Check if any statement in the compound is a return
            foreach (s; compound.statements) {
                if (branchContainsReturn(s)) {
                    return true;
                }
            }
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            // Nested if: only "returns" if both branches return
            bool thenRet = branchContainsReturn(ifStmt.thenStatement);
            bool elseRet = ifStmt.elseStatement !is null && branchContainsReturn(ifStmt.elseStatement);
            return thenRet && elseRet;
        }
        return false;
    }
    
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

    /**
     * Generate while statement
     */
    string generateWhileStatement(WhileStatement stmt) {
        string conditionCode = generateExpression(stmt.condition);
        string bodyCode = generateStatement(stmt.body_);
        
        string[string] params;
        params["CONDITION_EXPRESSION"] = conditionCode;
        params["BODY_CODE"] = bodyCode;
        params["LOOP_ID"] = to!string(context.nextLoopId++);
        
        return templateEngine.substitute("control_flow/while_statement", params);
    }
    
    /**
     * Generate for statement
     */
    string generateForStatement(ForStatement stmt) {
        string initCode = stmt.init ? generateStatement(stmt.init) : "";
        string conditionCode = stmt.condition ? generateExpression(stmt.condition) : "i32.const 1";
        string bodyCode = generateStatement(stmt.body_);
        string updateCode = "";
        
        if (stmt.update) {
            updateCode = generateExpression(stmt.update) ~ "\ndrop";
        }
        
        string[string] params;
        params["INIT_CODE"] = initCode;
        params["CONDITION_EXPRESSION"] = conditionCode;
        params["BODY_CODE"] = bodyCode;
        params["UPDATE_CODE"] = updateCode;
        params["LOOP_ID"] = to!string(context.nextLoopId++);
        
        return templateEngine.substitute("control_flow/for_statement", params);
    }
    
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
        string funcName = "unknown";
        if (auto identExpr = cast(IdentifierExpression)expr.function_) {
            funcName = identExpr.name;
        }
        
        // Special handling for writeln() - map to WASI console output
        if (funcName == "writeln") {
            return generateWritelnCall(expr);
        }
        
        string args = "";
        foreach (arg; expr.arguments) {
            args ~= generateExpression(arg) ~ "\n";
        }
        
        string[string] params;
        params["ARGUMENTS"] = args;
        params["FUNCTION_NAME"] = funcName;
        
        return templateEngine.substitute("core/function_call", params);
    }
    
    /**
     * Generate WASI-compatible writeln() call
     */
    private string generateWritelnCall(CallExpression expr) {
        if (expr.arguments.length == 0) {
            // writeln() with no arguments - just print newline
            return generateWritelnNewline();
        }
        
        string result = "";
        foreach (arg; expr.arguments) {
            if (auto literal = cast(LiteralExpression)arg) {
                if (literal.value.type == typeid(string)) {
                    // String literal - add to data section and generate call
                    string str = literal.value.get!string();
                    result ~= generateWritelnString(str);
                } else if (literal.value.type == typeid(long)) {
                    // Integer literal - convert to string and output
                    long val = literal.value.get!long();
                    result ~= generateWritelnInteger(val);
                }
            } else {
                // For complex expressions, we'd need runtime string conversion
                // For now, treat as placeholder
                result ~= ";; TODO: Complex expression writeln(" ~ arg.toString() ~ ")\n";
            }
        }
        
        return result;
    }
    
    /**
     * Generate string data and WASI call for string literal
     */
    private string generateWritelnString(string str) {
        // Add newline to string
        string strWithNewline = str ~ "\n";
        
        // Find next available memory offset (simple strategy)
        uint offset = getNextStringOffset();
        
        // Add string to data section
        addStringToDataSection(strWithNewline, offset);
        
        // Generate call to write_str with offset and length
        return format("  (call $write_str (i32.const %d) (i32.const %d))\n", 
                     offset, strWithNewline.length);
    }
    
    /**
     * Generate WASI call for integer output
     */
    private string generateWritelnInteger(long value) {
        // Convert integer to string with newline
        string strValue = format("%d\n", value);
        
        uint offset = getNextStringOffset();
        addStringToDataSection(strValue, offset);
        
        return format("  (call $write_str (i32.const %d) (i32.const %d))\n",
                     offset, strValue.length);
    }
    
    /**
     * Generate writeln() with just newline
     */
    private string generateWritelnNewline() {
        uint offset = getNextStringOffset();
        addStringToDataSection("\n", offset);
        
        return format("  (call $write_str (i32.const %d) (i32.const %d))\n",
                     offset, 1);
    }
    
    /**
     * Simple string memory allocation strategy
     */
    private uint nextStringOffset = 100;  // Start strings at offset 100
    
    private uint getNextStringOffset() {
        uint current = nextStringOffset;
        nextStringOffset += 50;  // Leave 50 bytes between strings
        return current;
    }
    
    /**
     * Add string to module data section
     */
    private void addStringToDataSection(string str, uint offset) {
        // Escape the string for WAT format
        string escapedStr = str.replace("\\", "\\\\")
                              .replace("\"", "\\\"")
                              .replace("\n", "\\n")
                              .replace("\r", "\\r")
                              .replace("\t", "\\t");
        string dataEntry = format("(data (i32.const %d) \"%s\")", offset, escapedStr);
        
        // Add to module data section (we'll need to modify WasmModule for this)
        // For now, store in a temporary array
        pendingDataEntries ~= dataEntry;
    }
    
    // Temporary storage for data entries
    private string[] pendingDataEntries;
    
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