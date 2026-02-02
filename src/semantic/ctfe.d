/**
 * Compile-Time Function Evaluation (CTFE)
 * 
 * This module evaluates expressions at compile time by:
 * 1. Compiling required functions to WASM
 * 2. Running them with wasm3
 * 3. Returning the result
 */
module semantic.ctfe;

import ast.nodes;
import ast.statements;
import ast.expressions;
import semantic.symbol_table;
import codegen.emitter;
import codegen.wasm;
import parser.tree_sitter_bridge : TreeSitterBridge;

import std.stdio;
import std.path;
import std.conv;
import std.format;
import std.array;
import std.string;

/**
 * CTFE evaluation error
 */
class CTFEError : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

/**
 * Result of a CTFE evaluation that can be either a string or integer.
 */
struct CTFEResult {
    bool isString;
    string stringValue;
    long intValue;
    
    static CTFEResult fromString(string s) {
        return CTFEResult(true, s, 0);
    }
    
    static CTFEResult fromInt(long v) {
        return CTFEResult(false, "", v);
    }
}

/**
 * CTFE Evaluator
 * 
 * Evaluates compile-time expressions by compiling to WASM and running with wasm3.
 */
class CTFEEvaluator {
    private SymbolTable symbolTable;
    private Declaration[] allDeclarations;
    
    // CTFE Arena for __ctfe_runtime memory allocation
    private static struct CTFEArena {
        enum MEMORY_RESERVED = 1024;  // First 1KB reserved for future use
        uint offset = MEMORY_RESERVED;
        uint[] savedOffsets;  // Stack for push/pop
        
        int alloc(int size) {
            // 8-byte align
            uint aligned = (offset + 7) & ~7;
            offset = aligned + size;
            return cast(int)aligned;
        }
        
        void push() {
            savedOffsets ~= offset;
        }
        
        void pop() {
            if (savedOffsets.length == 0) {
                throw new Exception("CTFE: Arena pop without matching push");
            }
            offset = savedOffsets[$-1];
            savedOffsets = savedOffsets[0..$-1];
        }
        
        int remaining() {
            // Assume 64KB WASM memory limit for CTFE
            enum MEMORY_SIZE = 64 * 1024;
            return MEMORY_SIZE - offset;
        }
        
        void reset() {
            offset = MEMORY_RESERVED;
            savedOffsets = [];
        }
    }
    private CTFEArena arena;
    
    this(SymbolTable symbolTable, Declaration[] declarations) {
        this.symbolTable = symbolTable;
        this.allDeclarations = declarations;
    }
    
    /**
     * Evaluate a member call like __ctfe_runtime.alloc(100)
     */
    private CTFEResult evaluateMemberCall(MemberExpression memberExpr, Expression[] arguments) {
        // Check if this is a __ctfe_runtime call
        if (auto objIdent = cast(IdentifierExpression)memberExpr.object) {
            if (objIdent.name == "__ctfe_runtime") {
                return evaluateCTFERuntimeCall(memberExpr.memberName, arguments);
            }
        }
        
        throw new CTFEError("CTFE: Member calls not supported except for magic modules");
    }
    
    /**
     * Evaluate a __ctfe_runtime function call
     */
    private CTFEResult evaluateCTFERuntimeCall(string funcName, Expression[] arguments) {
        writeln("CTFE: __ctfe_runtime.", funcName, " called");
        
        switch (funcName) {
            case "alloc":
                if (arguments.length != 1) {
                    throw new CTFEError("CTFE: __ctfe_runtime.alloc requires 1 argument");
                }
                int size = cast(int)evaluateSimpleExpression(arguments[0]);
                int ptr = arena.alloc(size);
                writeln("CTFE: __ctfe_runtime.alloc(", size, ") = ", ptr);
                return CTFEResult.fromInt(ptr);
                
            case "push":
                if (arguments.length != 0) {
                    throw new CTFEError("CTFE: __ctfe_runtime.push takes no arguments");
                }
                arena.push();
                writeln("CTFE: __ctfe_runtime.push()");
                return CTFEResult.fromInt(0);
                
            case "pop":
                if (arguments.length != 0) {
                    throw new CTFEError("CTFE: __ctfe_runtime.pop takes no arguments");
                }
                arena.pop();
                writeln("CTFE: __ctfe_runtime.pop()");
                return CTFEResult.fromInt(0);
                
            case "remaining":
                if (arguments.length != 0) {
                    throw new CTFEError("CTFE: __ctfe_runtime.remaining takes no arguments");
                }
                int rem = arena.remaining();
                writeln("CTFE: __ctfe_runtime.remaining() = ", rem);
                return CTFEResult.fromInt(rem);
                
            default:
                throw new CTFEError("CTFE: Unknown __ctfe_runtime function: " ~ funcName);
        }
    }
    
    /**
     * Evaluate all manifest constants in the declarations
     */
    void evaluateManifestConstants() {
        foreach (decl; allDeclarations) {
            if (auto manifest = cast(ManifestConstantDecl)decl) {
                evaluateManifestConstant(manifest);
            }
        }
    }
    
    /**
     * Evaluate a single manifest constant
     */
    void evaluateManifestConstant(ManifestConstantDecl manifest) {
        writeln("CTFE: Evaluating ", manifest.name);
        
        // Check if it's a simple literal (no CTFE needed)
        if (auto literal = cast(LiteralExpression)manifest.initializer) {
            if (literal.value.type == typeid(long)) {
                long value = literal.value.get!long();
                // Check for i32 overflow
                if (value > int.max || value < int.min) {
                    throw new CTFEError(
                        format("Integer literal %d exceeds i32 range [%d, %d] for '%s'",
                               value, int.min, int.max, manifest.name)
                    );
                }
                manifest.ctfeValue = value;
                manifest.ctfeComplete = true;
                manifest.inferredType = new BasicType(manifest.location, BasicType.Kind.Int32);
                writeln("CTFE: ", manifest.name, " = ", manifest.ctfeValue, " (literal)");
                return;
            }
            if (literal.value.type == typeid(string)) {
                manifest.ctfeStringValue = literal.value.get!string();
                manifest.ctfeComplete = true;
                manifest.isStringType = true;
                // TODO: proper string type
                writeln("CTFE: ", manifest.name, " = \"", manifest.ctfeStringValue, "\" (string literal)");
                return;
            }
            if (literal.value.type == typeid(char)) {
                // Char is stored as its integer value (same as D semantics)
                manifest.ctfeValue = cast(long)literal.value.get!char();
                manifest.ctfeComplete = true;
                manifest.inferredType = new BasicType(manifest.location, BasicType.Kind.Char);
                writeln("CTFE: ", manifest.name, " = '", literal.value.get!char(), "' (char literal)");
                return;
            }
            if (literal.value.type == typeid(bool)) {
                manifest.ctfeValue = literal.value.get!bool() ? 1 : 0;
                manifest.ctfeComplete = true;
                manifest.inferredType = new BasicType(manifest.location, BasicType.Kind.Bool);
                writeln("CTFE: ", manifest.name, " = ", manifest.ctfeValue ? "true" : "false", " (bool literal)");
                return;
            }
        }
        
        // Check for unary expression (e.g., -42)
        if (auto unaryExpr = cast(UnaryExpression)manifest.initializer) {
            if (unaryExpr.operator == UnaryExpression.Operator.Minus) {
                // Evaluate the operand
                long operand = evaluateSimpleExpression(unaryExpr.operand);
                long value = -operand;
                // Check for i32 overflow
                if (value > int.max || value < int.min) {
                    throw new CTFEError(
                        format("Integer value %d exceeds i32 range [%d, %d] for '%s'",
                               value, int.min, int.max, manifest.name)
                    );
                }
                manifest.ctfeValue = value;
                manifest.ctfeComplete = true;
                manifest.inferredType = new BasicType(manifest.location, BasicType.Kind.Int32);
                writeln("CTFE: ", manifest.name, " = ", manifest.ctfeValue, " (unary minus)");
                return;
            }
        }
        
        // Check for binary expression (e.g., array/string concatenation)
        if (auto binaryExpr = cast(BinaryExpression)manifest.initializer) {
            if (binaryExpr.operator == BinaryExpression.Operator.Concat) {
                // Determine if this is string or array concat
                if (isArrayConcatExpression(binaryExpr)) {
                    evaluateArrayConcat(manifest, binaryExpr);
                } else {
                    string result = evaluateStringConcat(binaryExpr);
                    manifest.ctfeStringValue = result;
                    manifest.ctfeComplete = true;
                    manifest.isStringType = true;
                    writeln("CTFE: ", manifest.name, " = \"", result, "\" (concatenated)");
                }
                return;
            }
        }
        
        // Check for function call that might return a string
        if (auto callExpr = cast(CallExpression)manifest.initializer) {
            auto result = evaluateCallExpressionString(callExpr);
            if (result.isString) {
                manifest.ctfeStringValue = result.stringValue;
                manifest.ctfeComplete = true;
                manifest.isStringType = true;
                writeln("CTFE: ", manifest.name, " = \"", result.stringValue, "\" (function call)");
                return;
            } else {
                manifest.ctfeValue = result.intValue;
                manifest.ctfeComplete = true;
                manifest.inferredType = new BasicType(manifest.location, BasicType.Kind.Int32);
                writeln("CTFE: ", manifest.name, " = ", manifest.ctfeValue, " (evaluated)");
                return;
            }
        }
        
        // Check for array literal
        if (auto arrayLit = cast(ArrayLiteralExpression)manifest.initializer) {
            evaluateArrayLiteral(manifest, arrayLit);
            return;
        }
        
        // Shouldn't reach here - call expressions are handled above
        // This is legacy code for non-call expressions that need WASM evaluation
        
        throw new CTFEError("Cannot evaluate manifest constant '" ~ manifest.name ~ 
                           "': unsupported initializer type");
    }
    
    /**
     * Evaluate string concatenation at compile time via WASM execution.
     * 
     * Uses the same BinaryEmitter codegen as final output:
     * 1. Emit a module with __eval function that evaluates the concat expression
     * 2. Execute in wasm3
     * 3. Read result string from memory
     * 
     * This ensures CTFE uses identical code paths to runtime.
     */
    string evaluateStringConcat(BinaryExpression expr) {
        import semantic.ctfe_runtime : CTFERuntime, CTFERuntimeError;
        import codegen.wasm : ARRAY_PTR_OFFSET, ARRAY_LEN_OFFSET;
        
        writeln("CTFE: Evaluating array concat via WASM");
        
        // First, ensure any manifest constants referenced are already evaluated
        ensureDependenciesEvaluated(expr);
        
        // Emit a WASM module that evaluates this expression
        auto emitter = new BinaryEmitter(symbolTable);
        ubyte[] wasmBytes = emitter.emitArrayExpressionModule(expr);
        
        if (wasmBytes is null) {
            throw new CTFEError("CTFE: Failed to compile array expression: " ~ emitter.error());
        }
        
        // Debug: show the generated WASM size
        writeln("CTFE: Generated ", wasmBytes.length, " bytes of WASM");
        
        // Execute in wasm3
        auto runtime = new CTFERuntime();
        scope(exit) destroy(runtime);
        
        try {
            runtime.loadModule(wasmBytes);
            
            // Call __eval() to get the result string pointer
            auto result = runtime.callI32("__eval");
            uint structPtr = result.asInt();
            
            writeln("CTFE: __eval returned struct at ", structPtr);
            
            // Read the String struct from memory
            uint dataPtr = runtime.readU32(structPtr + ARRAY_PTR_OFFSET);
            uint len = runtime.readU32(structPtr + ARRAY_LEN_OFFSET);
            
            writeln("CTFE: String data at ", dataPtr, ", len=", len);
            
            // Read the string data
            string resultStr = runtime.readString(dataPtr, len);
            
            writeln("CTFE: Result = \"", resultStr, "\"");
            
            return resultStr;
            
        } catch (CTFERuntimeError e) {
            throw new CTFEError("CTFE: wasm3 execution failed: " ~ e.msg);
        }
    }
    
    /**
     * Ensure all manifest constants referenced in an expression are evaluated.
     */
    private void ensureDependenciesEvaluated(Expression expr) {
        if (auto ident = cast(IdentifierExpression)expr) {
            foreach (decl; allDeclarations) {
                if (auto manifest = cast(ManifestConstantDecl)decl) {
                    if (manifest.name == ident.name && !manifest.ctfeComplete) {
                        evaluateManifestConstant(manifest);
                    }
                }
            }
        } else if (auto binary = cast(BinaryExpression)expr) {
            ensureDependenciesEvaluated(binary.left);
            ensureDependenciesEvaluated(binary.right);
        } else if (auto call = cast(CallExpression)expr) {
            // Evaluate dependencies in call arguments (e.g., __text(n))
            foreach (arg; call.arguments) {
                ensureDependenciesEvaluated(arg);
            }
        }
    }
    
    /**
     * Evaluate an array literal at compile time.
     * Stores elements as raw bytes for codegen.
     */
    void evaluateArrayLiteral(ManifestConstantDecl manifest, ArrayLiteralExpression arrayLit) {
        import std.array : appender;
        
        // Evaluate all elements
        long[] values;
        foreach (elem; arrayLit.elements) {
            values ~= evaluateSimpleExpression(elem);
        }
        
        // Determine element size (assume i32 for now - 4 bytes)
        // TODO: proper type inference
        uint elementSize = 4;
        
        // Convert to bytes (little-endian)
        auto bytes = appender!(ubyte[]);
        foreach (val; values) {
            int v = cast(int)val;
            bytes ~= cast(ubyte)(v & 0xFF);
            bytes ~= cast(ubyte)((v >> 8) & 0xFF);
            bytes ~= cast(ubyte)((v >> 16) & 0xFF);
            bytes ~= cast(ubyte)((v >> 24) & 0xFF);
        }
        
        manifest.ctfeArrayValue = values;
        manifest.ctfeArrayBytes = bytes.data;
        manifest.ctfeElementSize = elementSize;
        manifest.ctfeComplete = true;
        manifest.isArrayType = true;
        
        writeln("CTFE: ", manifest.name, " = ", values, " (array literal, ", bytes.data.length, " bytes)");
    }
    
    /**
     * Check if a concat expression is array concat (vs string concat).
     * Returns true if either operand is an array literal or array manifest constant.
     */
    bool isArrayConcatExpression(BinaryExpression expr) {
        return isArrayExpression(expr.left) || isArrayExpression(expr.right);
    }
    
    /**
     * Check if an expression evaluates to an array (not string).
     */
    bool isArrayExpression(Expression expr) {
        // Direct array literal
        if (cast(ArrayLiteralExpression)expr) {
            return true;
        }
        
        // Manifest constant reference - check if it's an array
        if (auto ident = cast(IdentifierExpression)expr) {
            foreach (decl; allDeclarations) {
                if (auto manifest = cast(ManifestConstantDecl)decl) {
                    if (manifest.name == ident.name) {
                        if (!manifest.ctfeComplete) {
                            evaluateManifestConstant(manifest);
                        }
                        return manifest.isArrayType;
                    }
                }
            }
        }
        
        // Nested concat - check recursively
        if (auto binary = cast(BinaryExpression)expr) {
            if (binary.operator == BinaryExpression.Operator.Concat) {
                return isArrayConcatExpression(binary);
            }
        }
        
        return false;
    }
    
    /**
     * Evaluate array concatenation at compile time.
     * For simplicity, we do this in D rather than WASM (arrays are just bytes).
     */
    void evaluateArrayConcat(ManifestConstantDecl manifest, BinaryExpression expr) {
        import std.array : appender;
        
        writeln("CTFE: Evaluating array concat");
        
        // Ensure operands are evaluated
        ensureDependenciesEvaluated(expr);
        
        // Get array bytes from both operands
        auto leftBytes = getArrayBytes(expr.left);
        auto rightBytes = getArrayBytes(expr.right);
        
        // Concatenate bytes
        auto combined = appender!(ubyte[]);
        combined ~= leftBytes;
        combined ~= rightBytes;
        
        // Also concatenate values for display
        auto leftVals = getArrayValues(expr.left);
        auto rightVals = getArrayValues(expr.right);
        long[] combinedVals = leftVals ~ rightVals;
        
        manifest.ctfeArrayValue = combinedVals;
        manifest.ctfeArrayBytes = combined.data;
        manifest.ctfeElementSize = 4;  // Assume i32 for now
        manifest.ctfeComplete = true;
        manifest.isArrayType = true;
        
        writeln("CTFE: ", manifest.name, " = ", combinedVals, " (array concat, ", combined.data.length, " bytes)");
    }
    
    /**
     * Get the raw bytes of an array expression.
     */
    ubyte[] getArrayBytes(Expression expr) {
        import std.array : appender;
        
        // Array literal
        if (auto arrayLit = cast(ArrayLiteralExpression)expr) {
            auto bytes = appender!(ubyte[]);
            foreach (elem; arrayLit.elements) {
                long val = evaluateSimpleExpression(elem);
                int v = cast(int)val;
                bytes ~= cast(ubyte)(v & 0xFF);
                bytes ~= cast(ubyte)((v >> 8) & 0xFF);
                bytes ~= cast(ubyte)((v >> 16) & 0xFF);
                bytes ~= cast(ubyte)((v >> 24) & 0xFF);
            }
            return bytes.data;
        }
        
        // Manifest constant reference
        if (auto ident = cast(IdentifierExpression)expr) {
            foreach (decl; allDeclarations) {
                if (auto manifest = cast(ManifestConstantDecl)decl) {
                    if (manifest.name == ident.name && manifest.ctfeComplete && manifest.isArrayType) {
                        return manifest.ctfeArrayBytes;
                    }
                }
            }
        }
        
        // Nested concat
        if (auto binary = cast(BinaryExpression)expr) {
            if (binary.operator == BinaryExpression.Operator.Concat) {
                auto left = getArrayBytes(binary.left);
                auto right = getArrayBytes(binary.right);
                return left ~ right;
            }
        }
        
        throw new CTFEError("Cannot get array bytes from expression");
    }
    
    /**
     * Get the values of an array expression (for display).
     */
    long[] getArrayValues(Expression expr) {
        // Array literal
        if (auto arrayLit = cast(ArrayLiteralExpression)expr) {
            long[] values;
            foreach (elem; arrayLit.elements) {
                values ~= evaluateSimpleExpression(elem);
            }
            return values;
        }
        
        // Manifest constant reference
        if (auto ident = cast(IdentifierExpression)expr) {
            foreach (decl; allDeclarations) {
                if (auto manifest = cast(ManifestConstantDecl)decl) {
                    if (manifest.name == ident.name && manifest.ctfeComplete && manifest.isArrayType) {
                        return manifest.ctfeArrayValue;
                    }
                }
            }
        }
        
        // Nested concat
        if (auto binary = cast(BinaryExpression)expr) {
            if (binary.operator == BinaryExpression.Operator.Concat) {
                return getArrayValues(binary.left) ~ getArrayValues(binary.right);
            }
        }
        
        return [];
    }
    
    /**
     * Evaluate a function call at compile time, supporting both integer and string returns.
     */
    CTFEResult evaluateCallExpressionString(CallExpression callExpr) {
        // Check for member expression calls like __ctfe_runtime.alloc()
        if (auto memberExpr = cast(MemberExpression)callExpr.function_) {
            return evaluateMemberCall(memberExpr, callExpr.arguments);
        }
        
        // Get the function name
        auto identExpr = cast(IdentifierExpression)callExpr.function_;
        if (!identExpr) {
            throw new CTFEError("CTFE: Indirect function calls not supported");
        }
        
        // Handle CTFE intrinsics
        if (identExpr.name == "__writeln") {
            return CTFEResult.fromInt(evaluateCtfeWriteln(callExpr));
        }
        string funcName = identExpr.name;
        
        // Find the function declaration
        FunctionDecl funcDecl = null;
        foreach (decl; allDeclarations) {
            if (auto fd = cast(FunctionDecl)decl) {
                if (fd.name == funcName) {
                    funcDecl = fd;
                    break;
                }
            }
        }
        
        if (!funcDecl) {
            throw new CTFEError("CTFE: Function '" ~ funcName ~ "' not found");
        }
        
        // Check if function returns a string
        bool returnsString = false;
        if (auto userType = cast(UserType)funcDecl.returnType) {
            if (userType.name == "string") {
                returnsString = true;
            }
        }
        
        writeln("CTFE: Calling ", funcName, " (returns string: ", returnsString, ")");
        
        // For string-returning functions, interpret directly
        if (returnsString) {
            return CTFEResult.fromString(interpretStringFunction(funcDecl));
        }
        
        // Check if this is a simple function that only contains CTFE intrinsics
        if (canInterpretDirectly(funcDecl)) {
            writeln("CTFE: Interpreting ", funcName, " directly");
            return CTFEResult.fromInt(interpretFunction(funcDecl));
        }
        
        // Check if function uses __ctfe_runtime - if so, interpret it
        if (usesCTFERuntime(funcDecl)) {
            writeln("CTFE: Function uses __ctfe_runtime, interpreting directly");
            return interpretIntFunction(funcDecl);
        }
        
        // Evaluate arguments (must be literals or simple expressions)
        long[] args;
        foreach (arg; callExpr.arguments) {
            args ~= evaluateSimpleExpression(arg);
        }
        
        writeln("CTFE: Calling ", funcName, " with args ", args);
        
        // Compile function to WASM
        ubyte[] wasmBytes = compileFunctionToWasm(funcDecl);
        
        if (wasmBytes is null) {
            throw new CTFEError("CTFE: Failed to compile function '" ~ funcName ~ "'");
        }
        
        // Execute with wasm3
        long result = executeWasm(wasmBytes, funcName, args);
        
        return CTFEResult.fromInt(result);
    }
    
    /**
     * Evaluate a function call at compile time
     * Returns 0 for void functions (legacy - use evaluateCallExpressionString for new code)
     */
    long evaluateCallExpression(CallExpression callExpr) {
        auto result = evaluateCallExpressionString(callExpr);
        if (result.isString) {
            throw new CTFEError("CTFE: Expected integer result but got string");
        }
        return result.intValue;
    }
    
    /**
     * Interpret a function that returns a string.
     * Handles functions with mixins, local variables, and return statements.
     */
    string interpretStringFunction(FunctionDecl funcDecl) {
        writeln("CTFE: Interpreting string function ", funcDecl.name);
        
        if (!funcDecl.body_) {
            throw new CTFEError("CTFE: Function '" ~ funcDecl.name ~ "' has no body");
        }
        
        // Create a local variable scope for this function
        string[string] localStrings;
        long[string] localInts;
        
        // Execute statements
        if (auto compound = cast(CompoundStatement)funcDecl.body_) {
            auto result = executeStatementsForString(compound.statements, localStrings, localInts);
            if (result.hasReturn) {
                return result.value;
            }
        }
        
        throw new CTFEError("CTFE: Function '" ~ funcDecl.name ~ "' did not return a value");
    }
    
    /**
     * Result of executing statements during CTFE
     */
    private struct StatementResult {
        bool hasReturn;
        string value;
    }
    
    /**
     * Execute a list of statements, handling mixins and returns.
     */
    private StatementResult executeStatementsForString(Statement[] statements, 
                                                       ref string[string] localStrings,
                                                       ref long[string] localInts) {
        foreach (stmt; statements) {
            // Handle mixin statements - expand and execute them
            if (auto mixinStmt = cast(MixinStatement)stmt) {
                auto expanded = executeMixinStatement(mixinStmt, localStrings, localInts);
                if (expanded.hasReturn) {
                    return expanded;
                }
                continue;
            }
            
            // Handle variable declarations (local strings/ints)
            if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
                executeVarDecl(varDecl, localStrings, localInts);
                continue;
            }
            
            // Handle return statement
            if (auto returnStmt = cast(ReturnStatement)stmt) {
                if (returnStmt.value) {
                    string result = evaluateStringExpressionWithLocals(returnStmt.value, localStrings, localInts);
                    return StatementResult(true, result);
                }
            }
        }
        
        return StatementResult(false, "");
    }
    
    /**
     * Execute a mixin statement during CTFE - expand it and execute the resulting statements.
     */
    private StatementResult executeMixinStatement(MixinStatement mixinStmt,
                                                  ref string[string] localStrings,
                                                  ref long[string] localInts) {
        writeln("CTFE: Expanding mixin inside function: ", mixinStmt.mixinExpr.toString());
        
        // Evaluate the mixin expression to get the code string
        string code = evaluateStringExpressionWithLocals(mixinStmt.mixinExpr, localStrings, localInts);
        writeln("CTFE: Mixin expands to: \"", code, "\"");
        
        // Parse the code as statements
        string wrappedCode = "void __mixin_wrapper() { " ~ code ~ " }";
        auto bridge = new TreeSitterBridge("(ctfe-mixin)", wrappedCode);
        Declaration[] parsed = bridge.parseSourceFile();
        
        if (parsed.length > 0) {
            if (auto funcDecl = cast(FunctionDecl)parsed[0]) {
                if (auto compound = cast(CompoundStatement)funcDecl.body_) {
                    // Execute the expanded statements
                    return executeStatementsForString(compound.statements, localStrings, localInts);
                }
            }
        }
        
        return StatementResult(false, "");
    }
    
    /**
     * Execute a variable declaration during CTFE.
     */
    private void executeVarDecl(VariableDeclarationStatement varDecl,
                                ref string[string] localStrings,
                                ref long[string] localInts) {
        // Check if this is a string variable
        bool isString = false;
        if (auto userType = cast(UserType)varDecl.type) {
            if (userType.name == "string") {
                isString = true;
            }
        }
        
        if (isString && varDecl.initializer) {
            string value = evaluateStringExpressionWithLocals(varDecl.initializer, localStrings, localInts);
            localStrings[varDecl.name] = value;
            writeln("CTFE: Local string '", varDecl.name, "' = \"", value, "\"");
        } else if (varDecl.initializer) {
            // Assume integer
            long value = evaluateSimpleExpressionWithLocals(varDecl.initializer, localInts);
            localInts[varDecl.name] = value;
            writeln("CTFE: Local int '", varDecl.name, "' = ", value);
        }
    }
    
    /**
     * Evaluate a simple (integer) expression with local variables.
     */
    private long evaluateSimpleExpressionWithLocals(Expression expr, long[string] localInts) {
        if (auto literal = cast(LiteralExpression)expr) {
            if (literal.value.type == typeid(long)) {
                return literal.value.get!long();
            }
            if (literal.value.type == typeid(bool)) {
                return literal.value.get!bool() ? 1 : 0;
            }
        }
        
        if (auto ident = cast(IdentifierExpression)expr) {
            if (auto val = ident.name in localInts) {
                return *val;
            }
            // Try manifest constants
            foreach (decl; allDeclarations) {
                if (auto manifest = cast(ManifestConstantDecl)decl) {
                    if (manifest.name == ident.name && manifest.ctfeComplete && !manifest.isStringType) {
                        return manifest.ctfeValue;
                    }
                }
            }
        }
        
        return evaluateSimpleExpression(expr);
    }
    
    /**
     * Evaluate an expression that produces a string, including local variables.
     */
    string evaluateStringExpressionWithLocals(Expression expr, 
                                              string[string] localStrings,
                                              long[string] localInts) {
        // String literal
        if (auto literal = cast(LiteralExpression)expr) {
            if (literal.value.type == typeid(string)) {
                return literal.value.get!string();
            }
            throw new CTFEError("CTFE: Expected string literal");
        }
        
        // Identifier - check local variables first, then manifest constants
        if (auto ident = cast(IdentifierExpression)expr) {
            // Check local strings
            if (auto val = ident.name in localStrings) {
                return *val;
            }
            
            // Check manifest constants
            foreach (decl; allDeclarations) {
                if (auto manifest = cast(ManifestConstantDecl)decl) {
                    if (manifest.name == ident.name && manifest.ctfeComplete && manifest.isStringType) {
                        return manifest.ctfeStringValue;
                    }
                }
            }
            throw new CTFEError("CTFE: Undefined string identifier '" ~ ident.name ~ "'");
        }
        
        // String concatenation
        if (auto binary = cast(BinaryExpression)expr) {
            if (binary.operator == BinaryExpression.Operator.Concat) {
                return evaluateStringExpressionWithLocals(binary.left, localStrings, localInts) ~ 
                       evaluateStringExpressionWithLocals(binary.right, localStrings, localInts);
            }
        }
        
        throw new CTFEError("CTFE: Cannot evaluate expression as string");
    }
    
    /**
     * Check if a function uses __ctfe_runtime calls.
     */
    private bool usesCTFERuntime(FunctionDecl funcDecl) {
        if (!funcDecl.body_) return false;
        return statementUsesCTFERuntime(funcDecl.body_);
    }
    
    private bool statementUsesCTFERuntime(Statement stmt) {
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                if (statementUsesCTFERuntime(s)) return true;
            }
            return false;
        }
        
        if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
            if (varDecl.initializer && expressionUsesCTFERuntime(varDecl.initializer)) {
                return true;
            }
            return false;
        }
        
        if (auto exprStmt = cast(ExpressionStatement)stmt) {
            return expressionUsesCTFERuntime(exprStmt.expression);
        }
        
        if (auto returnStmt = cast(ReturnStatement)stmt) {
            if (returnStmt.value) {
                return expressionUsesCTFERuntime(returnStmt.value);
            }
            return false;
        }
        
        return false;
    }
    
    private bool expressionUsesCTFERuntime(Expression expr) {
        if (auto call = cast(CallExpression)expr) {
            if (auto member = cast(MemberExpression)call.function_) {
                if (auto obj = cast(IdentifierExpression)member.object) {
                    if (obj.name == "__ctfe_runtime") {
                        return true;
                    }
                }
            }
            // Check arguments too
            foreach (arg; call.arguments) {
                if (expressionUsesCTFERuntime(arg)) return true;
            }
        }
        
        if (auto member = cast(MemberExpression)expr) {
            return expressionUsesCTFERuntime(member.object);
        }
        
        if (auto binary = cast(BinaryExpression)expr) {
            return expressionUsesCTFERuntime(binary.left) || expressionUsesCTFERuntime(binary.right);
        }
        
        return false;
    }
    
    /**
     * Interpret a function that returns an integer and may use __ctfe_runtime.
     */
    private CTFEResult interpretIntFunction(FunctionDecl funcDecl) {
        writeln("CTFE: Interpreting int function ", funcDecl.name);
        
        if (!funcDecl.body_) {
            throw new CTFEError("CTFE: Function '" ~ funcDecl.name ~ "' has no body");
        }
        
        // Create local variable scope
        long[string] localInts;
        
        // Execute statements
        if (auto compound = cast(CompoundStatement)funcDecl.body_) {
            auto result = executeStatementsForInt(compound.statements, localInts);
            if (result.hasReturn) {
                return CTFEResult.fromInt(result.value);
            }
        }
        
        throw new CTFEError("CTFE: Function '" ~ funcDecl.name ~ "' did not return a value");
    }
    
    /**
     * Result of executing statements for int return
     */
    private struct IntStatementResult {
        bool hasReturn;
        long value;
    }
    
    /**
     * Execute statements and return an integer result.
     */
    private IntStatementResult executeStatementsForInt(Statement[] statements, ref long[string] localInts) {
        foreach (stmt; statements) {
            // Handle variable declarations
            if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
                if (varDecl.initializer) {
                    long value = evaluateIntExpressionWithLocals(varDecl.initializer, localInts);
                    localInts[varDecl.name] = value;
                    writeln("CTFE: Local '", varDecl.name, "' = ", value);
                }
                continue;
            }
            
            // Handle expression statements (e.g., __ctfe_runtime.push())
            if (auto exprStmt = cast(ExpressionStatement)stmt) {
                evaluateIntExpressionWithLocals(exprStmt.expression, localInts);
                continue;
            }
            
            // Handle return statement
            if (auto returnStmt = cast(ReturnStatement)stmt) {
                if (returnStmt.value) {
                    long result = evaluateIntExpressionWithLocals(returnStmt.value, localInts);
                    return IntStatementResult(true, result);
                }
                return IntStatementResult(true, 0);
            }
        }
        
        return IntStatementResult(false, 0);
    }
    
    /**
     * Evaluate an expression that produces an integer, with local variables and __ctfe_runtime support.
     */
    private long evaluateIntExpressionWithLocals(Expression expr, ref long[string] localInts) {
        // Literal
        if (auto literal = cast(LiteralExpression)expr) {
            if (literal.value.type == typeid(long)) {
                return literal.value.get!long();
            }
            if (literal.value.type == typeid(bool)) {
                return literal.value.get!bool() ? 1 : 0;
            }
        }
        
        // Identifier
        if (auto ident = cast(IdentifierExpression)expr) {
            if (auto val = ident.name in localInts) {
                return *val;
            }
            // Try manifest constants
            foreach (decl; allDeclarations) {
                if (auto manifest = cast(ManifestConstantDecl)decl) {
                    if (manifest.name == ident.name && manifest.ctfeComplete && !manifest.isStringType) {
                        return manifest.ctfeValue;
                    }
                }
            }
            throw new CTFEError("CTFE: Undefined identifier '" ~ ident.name ~ "'");
        }
        
        // Call expression (including __ctfe_runtime calls)
        if (auto call = cast(CallExpression)expr) {
            auto result = evaluateCallExpressionString(call);
            if (result.isString) {
                throw new CTFEError("CTFE: Expected integer but got string");
            }
            return result.intValue;
        }
        
        // Binary expression
        if (auto binary = cast(BinaryExpression)expr) {
            long left = evaluateIntExpressionWithLocals(binary.left, localInts);
            long right = evaluateIntExpressionWithLocals(binary.right, localInts);
            
            final switch (binary.operator) {
                case BinaryExpression.Operator.Add: return left + right;
                case BinaryExpression.Operator.Subtract: return left - right;
                case BinaryExpression.Operator.Multiply: return left * right;
                case BinaryExpression.Operator.Divide: return left / right;
                case BinaryExpression.Operator.Modulo: return left % right;
                case BinaryExpression.Operator.Equal: return left == right ? 1 : 0;
                case BinaryExpression.Operator.NotEqual: return left != right ? 1 : 0;
                case BinaryExpression.Operator.Less: return left < right ? 1 : 0;
                case BinaryExpression.Operator.LessEqual: return left <= right ? 1 : 0;
                case BinaryExpression.Operator.Greater: return left > right ? 1 : 0;
                case BinaryExpression.Operator.GreaterEqual: return left >= right ? 1 : 0;
                case BinaryExpression.Operator.LogicalAnd: return (left != 0 && right != 0) ? 1 : 0;
                case BinaryExpression.Operator.LogicalOr: return (left != 0 || right != 0) ? 1 : 0;
                case BinaryExpression.Operator.BitwiseAnd: return left & right;
                case BinaryExpression.Operator.BitwiseOr: return left | right;
                case BinaryExpression.Operator.BitwiseXor: return left ^ right;
                case BinaryExpression.Operator.ShiftLeft: return left << right;
                case BinaryExpression.Operator.ShiftRight: return left >> right;
                case BinaryExpression.Operator.Concat: 
                    throw new CTFEError("CTFE: String concat not supported in numeric context");
            }
        }
        
        throw new CTFEError("CTFE: Cannot evaluate expression at compile time: " ~ expr.toString());
    }
    
    /**
     * Evaluate an expression that produces a string (legacy - no locals).
     */
    string evaluateStringExpression(Expression expr) {
        string[string] emptyStrings;
        long[string] emptyInts;
        return evaluateStringExpressionWithLocals(expr, emptyStrings, emptyInts);
    }
    
    /**
     * Check if a function can be interpreted directly (only contains CTFE intrinsics)
     */
    bool canInterpretDirectly(FunctionDecl funcDecl) {
        if (!funcDecl.body_) return false;
        return containsOnlyIntrinsics(funcDecl.body_);
    }
    
    bool containsOnlyIntrinsics(Statement stmt) {
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                if (!containsOnlyIntrinsics(s)) return false;
            }
            return true;
        }
        
        if (auto exprStmt = cast(ExpressionStatement)stmt) {
            if (auto call = cast(CallExpression)exprStmt.expression) {
                if (auto ident = cast(IdentifierExpression)call.function_) {
                    // __writeln is an intrinsic we can interpret
                    if (ident.name == "__writeln") return true;
                }
            }
        }
        
        if (auto returnStmt = cast(ReturnStatement)stmt) {
            // Empty return is fine for void functions
            return returnStmt.value is null;
        }
        
        return false;
    }
    
    /**
     * Interpret a function directly (for functions with only CTFE intrinsics)
     */
    long interpretFunction(FunctionDecl funcDecl) {
        interpretStatement(funcDecl.body_);
        return 0;  // Void function returns 0
    }
    
    void interpretStatement(Statement stmt) {
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                interpretStatement(s);
            }
        } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
            interpretExpression(exprStmt.expression);
        } else if (auto returnStmt = cast(ReturnStatement)stmt) {
            // Void return - do nothing
        }
    }
    
    void interpretExpression(Expression expr) {
        if (auto call = cast(CallExpression)expr) {
            if (auto ident = cast(IdentifierExpression)call.function_) {
                if (ident.name == "__writeln") {
                    evaluateCtfeWriteln(call);
                }
            }
        }
    }
    
    /**
     * Handle __writeln intrinsic - prints during compile time
     */
    long evaluateCtfeWriteln(CallExpression callExpr) {
        import std.stdio : write, writeln;
        
        foreach (arg; callExpr.arguments) {
            if (auto literal = cast(LiteralExpression)arg) {
                // String literal
                if (literal.value.type == typeid(string)) {
                    write(literal.value.get!string());
                }
                // Integer literal
                else if (literal.value.type == typeid(long)) {
                    write(literal.value.get!long());
                }
                // Boolean literal
                else if (literal.value.type == typeid(bool)) {
                    write(literal.value.get!bool() ? "true" : "false");
                }
            } else if (auto ident = cast(IdentifierExpression)arg) {
                // Look up identifier - might be a manifest constant
                auto value = lookupCtfeValue(ident.name);
                write(value);
            } else {
                // Try to evaluate as simple expression (numbers)
                try {
                    long val = evaluateSimpleExpression(arg);
                    write(val);
                } catch (Exception e) {
                    write("<expr>");
                }
            }
        }
        writeln();  // Newline after all arguments
        
        return 0;  // __writeln returns void (0)
    }
    
    /**
     * Look up a CTFE value by name (manifest constant)
     */
    string lookupCtfeValue(string name) {
        // Search manifest constants
        foreach (decl; allDeclarations) {
            if (auto manifest = cast(ManifestConstantDecl)decl) {
                if (manifest.name == name && manifest.ctfeComplete) {
                    if (manifest.isStringType) {
                        return manifest.ctfeStringValue;
                    } else {
                        return to!string(manifest.ctfeValue);
                    }
                }
            }
        }
        
        // Not found
        return "<undefined:" ~ name ~ ">";
    }
    
    /**
     * Evaluate a simple expression (literal, binary op on literals)
     */
    long evaluateSimpleExpression(Expression expr) {
        if (auto literal = cast(LiteralExpression)expr) {
            if (literal.value.type == typeid(long)) {
                return literal.value.get!long();
            }
            if (literal.value.type == typeid(bool)) {
                return literal.value.get!bool() ? 1 : 0;
            }
            throw new CTFEError("CTFE: Unsupported literal type");
        }
        
        if (auto binary = cast(BinaryExpression)expr) {
            long left = evaluateSimpleExpression(binary.left);
            long right = evaluateSimpleExpression(binary.right);
            
            final switch (binary.operator) {
                case BinaryExpression.Operator.Add: return left + right;
                case BinaryExpression.Operator.Subtract: return left - right;
                case BinaryExpression.Operator.Multiply: return left * right;
                case BinaryExpression.Operator.Divide: return left / right;
                case BinaryExpression.Operator.Modulo: return left % right;
                case BinaryExpression.Operator.Equal: return left == right ? 1 : 0;
                case BinaryExpression.Operator.NotEqual: return left != right ? 1 : 0;
                case BinaryExpression.Operator.Less: return left < right ? 1 : 0;
                case BinaryExpression.Operator.LessEqual: return left <= right ? 1 : 0;
                case BinaryExpression.Operator.Greater: return left > right ? 1 : 0;
                case BinaryExpression.Operator.GreaterEqual: return left >= right ? 1 : 0;
                case BinaryExpression.Operator.LogicalAnd: return (left != 0 && right != 0) ? 1 : 0;
                case BinaryExpression.Operator.LogicalOr: return (left != 0 || right != 0) ? 1 : 0;
                case BinaryExpression.Operator.BitwiseAnd: return left & right;
                case BinaryExpression.Operator.BitwiseOr: return left | right;
                case BinaryExpression.Operator.BitwiseXor: return left ^ right;
                case BinaryExpression.Operator.ShiftLeft: return left << right;
                case BinaryExpression.Operator.ShiftRight: return left >> right;
                case BinaryExpression.Operator.Concat: 
                    throw new CTFEError("CTFE: String concat not supported in numeric context");
            }
        }
        
        throw new CTFEError("CTFE: Cannot evaluate expression at compile time");
    }
    
    /**
     * Compile a single function to WASM bytes
     */
    ubyte[] compileFunctionToWasm(FunctionDecl funcDecl) {
        // Create a minimal compilation with just this function
        auto emitter = new BinaryEmitter(symbolTable);
        auto result = emitter.emit([funcDecl]);
        
        if (result is null) {
            writeln("CTFE compile error: ", emitter.error());
        }
        
        return result;
    }
    
    /**
     * Execute WASM with embedded wasm3 runtime and return result
     */
    long executeWasm(ubyte[] wasmBytes, string funcName, long[] args) {
        import semantic.ctfe_runtime : CTFERuntime, CTFERuntimeError;
        
        writeln("CTFE: Executing ", funcName, " via embedded wasm3");
        
        auto runtime = new CTFERuntime();
        scope(exit) destroy(runtime);
        
        try {
            runtime.loadModule(wasmBytes);
            
            // Convert long[] to int[] for the call
            int[] intArgs;
            foreach (arg; args) {
                intArgs ~= cast(int)arg;
            }
            
            auto result = runtime.callI32(funcName, intArgs);
            writeln("CTFE: Result = ", result.asInt());
            return result.asInt();
            
        } catch (CTFERuntimeError e) {
            throw new CTFEError("CTFE: wasm3 execution failed: " ~ e.msg);
        }
    }
}
