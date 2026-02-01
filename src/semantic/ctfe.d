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
 * CTFE Evaluator
 * 
 * Evaluates compile-time expressions by compiling to WASM and running with wasm3.
 */
class CTFEEvaluator {
    private SymbolTable symbolTable;
    private Declaration[] allDeclarations;
    
    this(SymbolTable symbolTable, Declaration[] declarations) {
        this.symbolTable = symbolTable;
        this.allDeclarations = declarations;
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
                manifest.ctfeValue = literal.value.get!long();
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
        
        // Check for array literal
        if (auto arrayLit = cast(ArrayLiteralExpression)manifest.initializer) {
            evaluateArrayLiteral(manifest, arrayLit);
            return;
        }
        
        // Need to evaluate via WASM execution
        if (auto callExpr = cast(CallExpression)manifest.initializer) {
            long result = evaluateCallExpression(callExpr);
            manifest.ctfeValue = result;
            manifest.ctfeComplete = true;
            manifest.inferredType = new BasicType(manifest.location, BasicType.Kind.Int32);
            writeln("CTFE: ", manifest.name, " = ", manifest.ctfeValue, " (evaluated)");
            return;
        }
        
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
     * Evaluate a function call at compile time
     * Returns 0 for void functions
     */
    long evaluateCallExpression(CallExpression callExpr) {
        // Get the function name
        auto identExpr = cast(IdentifierExpression)callExpr.function_;
        if (!identExpr) {
            throw new CTFEError("CTFE: Indirect function calls not supported");
        }
        
        // Handle CTFE intrinsics
        if (identExpr.name == "__writeln") {
            return evaluateCtfeWriteln(callExpr);
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
        
        // Check if this is a simple function that only contains CTFE intrinsics
        // If so, interpret it directly instead of compiling to WASM
        if (canInterpretDirectly(funcDecl)) {
            writeln("CTFE: Interpreting ", funcName, " directly");
            return interpretFunction(funcDecl);
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
        
        return result;
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
