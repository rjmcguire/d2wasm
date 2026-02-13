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
import semantic.type_checker;
import codegen.emitter;
import codegen.wasm.types;
import codegen.backend;
import diagnostic.log : log;

import std.stdio;
import std.path;
import std.conv;
import std.format;
import std.array;
import std.string;
import core.time : MonoTime, Duration;

/**
 * CTFE evaluation error
 */
class CTFEError : Exception {
    SourceLocation location;

    struct Note {
        string message;
        SourceLocation location;
    }
    Note[] notes;

    this(string msg, SourceLocation location, string file = __FILE__, size_t line = __LINE__) {
        this.location = location;
        super(msg, file, line);
    }

    /// Add a note with source location context (e.g., "while evaluating ...")
    CTFEError addNote(string message, SourceLocation loc) {
        notes ~= Note(message, loc);
        return this;
    }
}

/**
 * Result of a CTFE evaluation that can be either a string, integer, or array.
 */
struct CTFEResult {
    bool isString;
    bool isArray;
    bool isStruct;
    string stringValue;
    long intValue;
    long[] arrayValues;
    ubyte[] arrayBytes;
    
    static CTFEResult fromString(string s) {
        CTFEResult r;
        r.isString = true;
        r.stringValue = s;
        return r;
    }
    
    static CTFEResult fromInt(long v) {
        CTFEResult r;
        r.intValue = v;
        return r;
    }
    
    static CTFEResult fromArray(long[] values, ubyte[] bytes) {
        CTFEResult r;
        r.isArray = true;
        r.arrayValues = values;
        r.arrayBytes = bytes;
        return r;
    }
    
    static CTFEResult fromStruct(long[] fieldValues, ubyte[] bytes) {
        CTFEResult r;
        r.isStruct = true;
        r.arrayValues = fieldValues;  // Struct field values (as ints)
        r.arrayBytes = bytes;         // Raw bytes
        return r;
    }
}

/**
 * CTFE Evaluator
 * 
 * Evaluates compile-time expressions by compiling to WASM and running with wasm3.
 */
/// Check if a type represents a string (dynamic ubyte[]).
/// Used by CTFE to detect string-returning functions and string locals.
private bool isStringType(Type t) {
    if (auto arrType = cast(ArrayType)t) {
        if (arrType.arraySize is null) { // dynamic array (slice), not static
            if (auto basic = cast(BasicType)arrType.elementType) {
                return basic.kind == BasicType.Kind.UInt8;
            }
        }
    }
    return false;
}

/// Deduce the type of an expression for IFTI in CTFE context.
/// Only handles literal types; more complex expressions default to Int32.
private Type deduceTypeFromExpression(Expression expr) {
    if (auto literal = cast(LiteralExpression)expr) {
        if (literal.value.type == typeid(long) || literal.value.type == typeid(int))
            return new BasicType(expr.location, BasicType.Kind.Int32);
        if (literal.value.type == typeid(bool))
            return new BasicType(expr.location, BasicType.Kind.Bool);
        if (literal.value.type == typeid(char))
            return new BasicType(expr.location, BasicType.Kind.Char);
    }
    // Default to int for manifest constant references and other expressions
    return new BasicType(expr.location, BasicType.Kind.Int32);
}

/// Compute a unique key for a function using D ABI mangling.
private string ctfeFuncKey(FunctionDecl func) {
    import codegen.mangle : computeMangledName;
    if (func.isMethod && func.parent !is null)
        return computeMangledName([], func);
    return func.name;
}

class CTFEEvaluator {
    private SymbolTable symbolTable;
    private Declaration[] allDeclarations;
    private Backend backend;  // Code generation backend (WASM or Native)
    private bool enableStackTrace;
    
    // Persistent CTFE context - accumulates compiled functions
    private bool[string] compiledFunctions;  // functions already in context
    private CompiledFunction cachedContext;  // reusable compiled module
    private FunctionDecl[] contextFunctions; // functions in current context
    
    // CTFE statistics
    private uint statFunctionsCompiled;   // total functions compiled
    private uint statCacheHits;           // times we reused cached context
    private uint statCacheMisses;         // times we needed to compile new functions
    private uint statCallCount;           // total CTFE calls
    private uint ctfeWrapperCounter;      // unique names for synthetic wrapper functions
    private Duration statCompileTime;     // total time spent compiling
    private Duration statExecTime;        // total time spent executing
    private Duration statAnalysisTime;    // total time in dependency analysis
    
    // CTFE Arena for __ctfe_runtime memory allocation
    private static struct CTFEArena {
        enum MEMORY_RESERVED = 2048;  // First 2KB reserved (call stack buffer + scratch)
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
    
    this(SymbolTable symbolTable, Declaration[] declarations, string backendName = "wasm", bool enableStackTrace = true) {
        this.symbolTable = symbolTable;
        this.allDeclarations = declarations;
        this.enableStackTrace = enableStackTrace;
        this.backend = createBackend(backendName, symbolTable, enableStackTrace);
        
        // Register lazy resolver with symbol table
        symbolTable.ctfeResolver = &this.evaluateManifestConstant;

        // Register template constraint evaluator
        symbolTable.constraintEvaluator = &this.evaluateTemplateConstraint;
    }
    
    /**
     * Get CTFE statistics as a formatted string.
     */
    string getStats() {
        import std.format : format;
        return format("CTFE Stats: %d calls, %d functions compiled, %d cache hits, %d cache misses",
            statCallCount, statFunctionsCompiled, statCacheHits, statCacheMisses);
    }

    private static string fmtDuration(Duration d) {
        import std.format : format;
        auto usecs = d.total!"usecs";
        if (usecs < 1000)
            return format("%d us", usecs);
        else if (usecs < 1_000_000)
            return format("%.2f ms", usecs / 1000.0);
        else
            return format("%.3f s", usecs / 1_000_000.0);
    }

    /**
     * Print CTFE statistics to stdout.
     */
    void printStats() {
        if (statCallCount > 0) {
            log(2, getStats());
            log(2, "  Functions in context: ", contextFunctions.length);
            if (statCallCount > 0) {
                auto hitRate = statCacheHits * 100 / statCallCount;
                log(2, "  Cache hit rate: ", hitRate, "%");
            }
            auto totalTime = statAnalysisTime + statCompileTime + statExecTime;
            log(2, "  Timing: analysis=", fmtDuration(statAnalysisTime),
                ", compile=", fmtDuration(statCompileTime),
                ", exec=", fmtDuration(statExecTime),
                ", total=", fmtDuration(totalTime));
        }
    }
    
    /**
     * Evaluate a member call like __ctfe_runtime.alloc(100)
     */
    private CTFEResult evaluateMemberCall(MemberExpression memberExpr, Expression[] arguments) {
        // Check if this is a __ctfe_runtime call
        if (auto objIdent = cast(IdentifierExpression)memberExpr.object) {
            if (objIdent.name == "__ctfe_runtime") {
                return evaluateCTFERuntimeCall(memberExpr.memberName, arguments, memberExpr.location);
            }
        }

        throw new CTFEError("CTFE: Member calls not supported except for magic modules", memberExpr.location);
    }

    /**
     * Evaluate a __ctfe_runtime function call
     */
    private CTFEResult evaluateCTFERuntimeCall(string funcName, Expression[] arguments, SourceLocation loc) {
        log(3, "CTFE: __ctfe_runtime.", funcName, " called");
        
        switch (funcName) {
            case "alloc":
                if (arguments.length != 1) {
                    throw new CTFEError("CTFE: __ctfe_runtime.alloc requires 1 argument", loc);
                }
                int size = cast(int)extractLiteralValue(arguments[0]);
                int ptr = arena.alloc(size);
                log(3, "CTFE: __ctfe_runtime.alloc(", size, ") = ", ptr);
                return CTFEResult.fromInt(ptr);
                
            case "push":
                if (arguments.length != 0) {
                    throw new CTFEError("CTFE: __ctfe_runtime.push takes no arguments", loc);
                }
                arena.push();
                log(3, "CTFE: __ctfe_runtime.push()");
                return CTFEResult.fromInt(0);
                
            case "pop":
                if (arguments.length != 0) {
                    throw new CTFEError("CTFE: __ctfe_runtime.pop takes no arguments", loc);
                }
                arena.pop();
                log(3, "CTFE: __ctfe_runtime.pop()");
                return CTFEResult.fromInt(0);
                
            case "remaining":
                if (arguments.length != 0) {
                    throw new CTFEError("CTFE: __ctfe_runtime.remaining takes no arguments", loc);
                }
                int rem = arena.remaining();
                log(3, "CTFE: __ctfe_runtime.remaining() = ", rem);
                return CTFEResult.fromInt(rem);
                
            default:
                throw new CTFEError("CTFE: Unknown __ctfe_runtime function: " ~ funcName, loc);
        }
    }
    
    /**
     * Evaluate a template constraint expression via CTFE.
     * Wraps the constraint in a synthetic function, compiles, and executes.
     * Throws TypeError if constraint evaluates to false, or on CTFE error.
     */
    void evaluateTemplateConstraint(Expression constraintExpr, SourceLocation loc,
                                    string templateName, string[] typeBindings) {
        import ast.statements : ReturnStatement, CompoundStatement;

        auto retStmt = new ReturnStatement(loc, constraintExpr);
        auto body_ = new CompoundStatement(loc, [cast(Statement)retStmt]);
        auto wrapper = new FunctionDecl(loc,
            "__constraint_check_" ~ to!string(ctfeWrapperCounter++),
            new BasicType(loc, BasicType.Kind.Bool), [], body_);

        long result;
        try {
            result = executeViaBackend(wrapper, []);
        } catch (CTFEError e) {
            throw new TypeError(
                format("While evaluating template constraint for '%s': %s",
                       templateName, e.msg), loc);
        } catch (Exception e) {
            throw new TypeError(
                format("While evaluating template constraint for '%s': %s",
                       templateName, e.msg), loc);
        }
        if (result == 0) {
            string msg = format("Template constraint not satisfied for '%s'\n  with:\n",
                                templateName);
            foreach (b; typeBindings)
                msg ~= format("    %s\n", b);
            msg ~= format("  constraint: %s = false", constraintExpr.toString());
            throw new TypeError(msg, loc);
        }
    }

    /** Evaluate all manifest constants in the declarations. */
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
        // Already evaluated? Skip.
        if (manifest.ctfeComplete) {
            return;
        }

        // Cycle detection: if we're already evaluating this manifest, it's circular
        if (manifest.ctfeInProgress) {
            throw new CTFEError(
                "circular dependency evaluating `enum " ~ manifest.name ~ "`",
                manifest.location);
        }

        manifest.ctfeInProgress = true;
        scope(exit) manifest.ctfeInProgress = false;

        // Save and restore symbol table scope state so CTFE evaluation
        // doesn't corrupt the caller's scope (re-entrancy protection)
        auto savedScope = symbolTable.saveAndResetScope();
        scope(exit) symbolTable.restoreScope(savedScope);

        try {
            evaluateManifestConstantImpl(manifest);
        } catch (CTFEError e) {
            // Add context note showing which manifest constant triggered the evaluation
            if (e.location != manifest.location) {
                throw e.addNote("while evaluating `enum " ~ manifest.name ~ "`", manifest.location);
            }
            throw e;
        }
    }

    private void evaluateManifestConstantImpl(ManifestConstantDecl manifest) {
        log(3, "CTFE: Evaluating ", manifest.name);

        // Check if it's a simple literal (no CTFE needed)
        if (auto literal = cast(LiteralExpression)manifest.initializer) {
            if (literal.value.type == typeid(long)) {
                long value = literal.value.get!long();
                // Allow both signed i32 and unsigned u32 range
                if (value > uint.max || value < int.min) {
                    throw new CTFEError(
                        format("Integer literal %d exceeds 32-bit range [%d, %d] for '%s'",
                               value, int.min, uint.max, manifest.name),
                        manifest.location
                    );
                }
                manifest.ctfeValue = value;
                manifest.ctfeComplete = true;
                manifest.inferredType = new BasicType(manifest.location, BasicType.Kind.Int32);
                log(3, "CTFE: ", manifest.name, " = ", manifest.ctfeValue, " (literal)");
                return;
            }
            if (literal.value.type == typeid(string)) {
                manifest.ctfeStringValue = literal.value.get!string();
                manifest.ctfeComplete = true;
                manifest.isStringType = true;
                // TODO: proper string type
                log(3, "CTFE: ", manifest.name, " = \"", manifest.ctfeStringValue, "\" (string literal)");
                return;
            }
            if (literal.value.type == typeid(char)) {
                // Char is stored as its integer value (same as D semantics)
                manifest.ctfeValue = cast(long)literal.value.get!char();
                manifest.ctfeComplete = true;
                manifest.inferredType = new BasicType(manifest.location, BasicType.Kind.Char);
                log(3, "CTFE: ", manifest.name, " = '", literal.value.get!char(), "' (char literal)");
                return;
            }
            if (literal.value.type == typeid(bool)) {
                manifest.ctfeValue = literal.value.get!bool() ? 1 : 0;
                manifest.ctfeComplete = true;
                manifest.inferredType = new BasicType(manifest.location, BasicType.Kind.Bool);
                log(3, "CTFE: ", manifest.name, " = ", manifest.ctfeValue ? "true" : "false", " (bool literal)");
                return;
            }
        }

        // Check for __traits expression (e.g., enum IS_INT = __traits(isArithmetic, int))
        if (auto traits = cast(TraitsExpression)manifest.initializer) {
            traits.evaluate();
            manifest.ctfeValue = traits.boolResult ? 1 : 0;
            manifest.ctfeComplete = true;
            manifest.inferredType = new BasicType(manifest.location, BasicType.Kind.Bool);
            log(3, "CTFE: ", manifest.name, " = ", traits.boolResult ? "true" : "false", " (__traits)");
            return;
        }

        // Check for unary expression (e.g., -42)
        if (auto unaryExpr = cast(UnaryExpression)manifest.initializer) {
            if (unaryExpr.operator == UnaryExpression.Operator.Minus) {
                // Evaluate the operand
                long operand = extractLiteralValue(unaryExpr.operand);
                long value = -operand;
                // Allow both signed i32 and unsigned u32 range
                if (value > uint.max || value < int.min) {
                    throw new CTFEError(
                        format("Integer value %d exceeds 32-bit range [%d, %d] for '%s'",
                               value, int.min, uint.max, manifest.name),
                        manifest.location
                    );
                }
                manifest.ctfeValue = value;
                manifest.ctfeComplete = true;
                manifest.inferredType = new BasicType(manifest.location, BasicType.Kind.Int32);
                log(3, "CTFE: ", manifest.name, " = ", manifest.ctfeValue, " (unary minus)");
                return;
            }
        }
        
        // Check for binary expression (e.g., array/string concatenation, arithmetic)
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
                    log(3, "CTFE: ", manifest.name, " = \"", result, "\" (concatenated)");
                }
                return;
            }
            // Shift operators — lower to checked operator function call
            if (binaryExpr.operator == BinaryExpression.Operator.ShiftLeft ||
                binaryExpr.operator == BinaryExpression.Operator.ShiftRight ||
                binaryExpr.operator == BinaryExpression.Operator.UnsignedShiftRight) {
                string funcName;
                if (binaryExpr.operator == BinaryExpression.Operator.ShiftLeft)
                    funcName = "opShiftLeft";
                else if (binaryExpr.operator == BinaryExpression.Operator.ShiftRight)
                    funcName = "opShiftRight";
                else
                    funcName = "opUnsignedShiftRight";
                auto callExpr = new CallExpression(binaryExpr.location,
                    new IdentifierExpression(binaryExpr.location, funcName),
                    [binaryExpr.left, binaryExpr.right]);
                auto result = evaluateCallExpressionString(callExpr);
                manifest.ctfeValue = result.intValue;
                manifest.ctfeComplete = true;
                manifest.inferredType = new BasicType(manifest.location, BasicType.Kind.Int32);
                log(3, "CTFE: ", manifest.name, " = ", manifest.ctfeValue, " (checked shift)");
                return;
            }
            // Arithmetic/comparison — evaluate via backend
            long value = evaluateExpressionViaBackend(binaryExpr);
            manifest.ctfeValue = value;
            manifest.ctfeComplete = true;
            manifest.inferredType = new BasicType(manifest.location, BasicType.Kind.Int32);
            log(3, "CTFE: ", manifest.name, " = ", manifest.ctfeValue, " (binary expression)");
            return;
        }
        
        // Check for function call that might return a string or array
        if (auto callExpr = cast(CallExpression)manifest.initializer) {
            auto result = evaluateCallExpressionString(callExpr);
            if (result.isString) {
                manifest.ctfeStringValue = result.stringValue;
                manifest.ctfeComplete = true;
                manifest.isStringType = true;
                log(3, "CTFE: ", manifest.name, " = \"", result.stringValue, "\" (function call)");
                return;
            } else if (result.isArray) {
                manifest.ctfeArrayValue = result.arrayValues;
                manifest.ctfeArrayBytes = result.arrayBytes;
                manifest.ctfeElementSize = 4;  // Assume int elements for now
                manifest.ctfeComplete = true;
                manifest.isArrayType = true;
                
                // Set the inferred type based on the function's return type
                if (auto funcIdent = cast(IdentifierExpression)callExpr.function_) {
                    foreach (decl; allDeclarations) {
                        if (auto fd = cast(FunctionDecl)decl) {
                            if (fd.name == funcIdent.name) {
                                manifest.inferredType = fd.returnType;
                                break;
                            }
                        }
                    }
                }
                
                log(3, "CTFE: ", manifest.name, " = ", result.arrayValues, " (array from function, ",
                    result.arrayBytes.length, " bytes)");
                return;
            } else {
                manifest.ctfeValue = result.intValue;
                manifest.ctfeComplete = true;
                manifest.inferredType = new BasicType(manifest.location, BasicType.Kind.Int32);
                log(3, "CTFE: ", manifest.name, " = ", manifest.ctfeValue, " (evaluated)");
                return;
            }
        }
        
        // Check for template instantiation call (e.g., enum RESULT = max!int(3, 8))
        if (auto tmplInst = cast(TemplateInstantiationExpression)manifest.initializer) {
            evaluateTemplateInstantiationCall(manifest, tmplInst);
            return;
        }

        // Check for array literal
        if (auto arrayLit = cast(ArrayLiteralExpression)manifest.initializer) {
            evaluateArrayLiteral(manifest, arrayLit);
            return;
        }
        
        // Check for import expression: import("filename")
        if (auto importExpr = cast(ImportExpression)manifest.initializer) {
            evaluateImportExpression(manifest, importExpr);
            return;
        }
        
        // Shouldn't reach here - call expressions are handled above
        // This is legacy code for non-call expressions that need WASM evaluation
        
        throw new CTFEError("Cannot evaluate manifest constant '" ~ manifest.name ~
                           "': unsupported initializer type", manifest.location);
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
        import codegen.wasm.types : ARRAY_PTR_OFFSET, ARRAY_LEN_OFFSET;
        
        log(3, "CTFE: Evaluating array concat via WASM");
        
        // First, ensure any manifest constants referenced are already evaluated
        ensureDependenciesEvaluated(expr);
        
        // Emit a WASM module that evaluates this expression
        auto emitter = new BinaryEmitter(symbolTable, enableStackTrace);
        ubyte[] wasmBytes = emitter.emitArrayExpressionModule(expr);
        
        if (wasmBytes is null) {
            throw new CTFEError("CTFE: Failed to compile array expression: " ~ emitter.error(), expr.location);
        }
        
        // Debug: show the generated WASM size
        log(3, "CTFE: Generated ", wasmBytes.length, " bytes of WASM");
        
        // Execute in wasm3
        auto runtime = new CTFERuntime();
        scope(exit) destroy(runtime);
        
        try {
            runtime.loadModule(wasmBytes);
            
            // Call __eval() to get the result string pointer
            auto result = runtime.callI32("__eval");
            uint structPtr = result.asInt();
            
            log(3, "CTFE: __eval returned struct at ", structPtr);
            
            // Read the String struct from memory
            uint dataPtr = runtime.readU32(structPtr + ARRAY_PTR_OFFSET);
            uint len = runtime.readU32(structPtr + ARRAY_LEN_OFFSET);
            
            log(3, "CTFE: String data at ", dataPtr, ", len=", len);
            
            // Read the string data
            string resultStr = runtime.readString(dataPtr, len);
            
            log(3, "CTFE: Result = \"", resultStr, "\"");
            
            return resultStr;
            
        } catch (CTFERuntimeError e) {
            throw new CTFEError("CTFE: wasm3 execution failed: " ~ e.msg, expr.location);
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
        } else if (auto unary = cast(UnaryExpression)expr) {
            ensureDependenciesEvaluated(unary.operand);
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
            values ~= extractLiteralValue(elem);
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
        
        log(3, "CTFE: ", manifest.name, " = ", values, " (array literal, ", bytes.data.length, " bytes)");
    }
    
    /**
     * Evaluate import("filename") expression.
     * Reads file at compile time and stores contents as ubyte[].
     */
    void evaluateImportExpression(ManifestConstantDecl manifest, ImportExpression importExpr) {
        import std.file : read, exists;
        import std.path : buildPath, dirName;
        
        string filename = importExpr.filename;
        
        // Try to find the file relative to the source file
        string sourcePath = importExpr.location.filename;
        string sourceDir = sourcePath.length > 0 ? dirName(sourcePath) : ".";
        string fullPath = buildPath(sourceDir, filename);
        
        // Also try current directory if not found
        if (!exists(fullPath)) {
            fullPath = filename;
        }
        
        if (!exists(fullPath)) {
            throw new CTFEError(
                format("import(\"%s\"): file not found (tried '%s' and '%s')",
                       filename, buildPath(sourceDir, filename), filename),
                importExpr.location
            );
        }
        
        log(3, "CTFE: Reading file '", fullPath, "'");
        
        // Read the file
        ubyte[] fileData;
        try {
            fileData = cast(ubyte[])read(fullPath);
        } catch (Exception e) {
            throw new CTFEError(
                format("import(\"%s\"): failed to read file: %s", filename, e.msg),
                importExpr.location
            );
        }
        
        // Store as array value
        manifest.ctfeArrayBytes = fileData;
        manifest.ctfeElementSize = 1;  // ubyte
        manifest.ctfeComplete = true;
        manifest.isArrayType = true;
        
        // Set the inferred type to ubyte[]
        auto ubyteType = new BasicType(manifest.location, BasicType.Kind.UInt8);
        manifest.inferredType = new ArrayType(manifest.location, ubyteType);
        
        log(3, "CTFE: ", manifest.name, " = import(\"", filename, "\") (", fileData.length, " bytes)");
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
        
        log(3, "CTFE: Evaluating array concat");
        
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
        
        log(3, "CTFE: ", manifest.name, " = ", combinedVals, " (array concat, ", combined.data.length, " bytes)");
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
                long val = extractLiteralValue(elem);
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
        
        throw new CTFEError("Cannot get array bytes from expression", expr.location);
    }
    
    /**
     * Get the values of an array expression (for display).
     */
    long[] getArrayValues(Expression expr) {
        // Array literal
        if (auto arrayLit = cast(ArrayLiteralExpression)expr) {
            long[] values;
            foreach (elem; arrayLit.elements) {
                values ~= extractLiteralValue(elem);
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
            throw new CTFEError("CTFE: Indirect function calls not supported", callExpr.location);
        }
        
        // Handle CTFE intrinsics
        if (identExpr.name == "__writeln") {
            return CTFEResult.fromInt(evaluateCtfeWriteln(callExpr));
        }

        // Compiler intrinsics — evaluate via backend (emitIntExpressionModule handles them)
        if (identExpr.name.length > 12 && identExpr.name[0..12] == "__intrinsic_") {
            long result = evaluateExpressionViaBackend(callExpr);
            return CTFEResult.fromInt(result);
        }

        string funcName = identExpr.name;

        // IFTI: if the call has a resolved instantiation, use it directly
        FunctionDecl funcDecl = callExpr.resolvedInstantiation;

        // Otherwise, find the function declaration by name
        if (!funcDecl) {
            foreach (decl; allDeclarations) {
                if (auto fd = cast(FunctionDecl)decl) {
                    if (fd.name == funcName) {
                        funcDecl = fd;
                        break;
                    }
                }
            }
        }

        // IFTI: if no direct FunctionDecl found, check for TemplateDecl
        if (!funcDecl) {
            import semantic.template_instantiation : TemplateInstantiator;

            TemplateDecl tmplDecl = null;
            FunctionDecl tmplFunc = null;
            foreach (decl; allDeclarations) {
                if (auto td = cast(TemplateDecl)decl) {
                    if (td.name == funcName) {
                        tmplDecl = td;
                        tmplFunc = cast(FunctionDecl)td.eponymousMember();
                        break;
                    }
                }
            }

            if (tmplDecl !is null && tmplFunc !is null) {
                // Deduce types from arguments
                Type[] deducedTypes = new Type[tmplDecl.templateParams.length];
                foreach (i, param; tmplFunc.parameters) {
                    if (i >= callExpr.arguments.length) break;
                    if (auto tpt = cast(TemplateParamType)param.type) {
                        foreach (j, tp; tmplDecl.templateParams) {
                            if (tp.paramName == tpt.paramName && deducedTypes[j] is null) {
                                deducedTypes[j] = deduceTypeFromExpression(callExpr.arguments[i]);
                                break;
                            }
                        }
                    }
                }

                // Verify all deduced
                foreach (i, dt; deducedTypes) {
                    if (dt is null) {
                        throw new CTFEError("CTFE: Cannot deduce template parameter '" ~
                            tmplDecl.templateParams[i].paramName ~ "'", callExpr.location);
                    }
                }

                auto instantiator = new TemplateInstantiator();
                auto inst = cast(FunctionDecl)instantiator.instantiate(tmplDecl, deducedTypes);
                if (!inst)
                    throw new CTFEError("CTFE: Template did not produce a function", callExpr.location);
                funcDecl = inst;
                callExpr.resolvedInstantiation = funcDecl;

                // Type-check the instantiation (save/restore scope for re-entrancy safety)
                {
                    auto saved = symbolTable.saveAndResetScope();
                    scope(exit) symbolTable.restoreScope(saved);
                    auto typeChecker = new TypeChecker(symbolTable);
                    typeChecker.checkFunctionDeclaration(funcDecl);
                }
            }
        }

        if (!funcDecl) {
            throw new CTFEError("CTFE: Function '" ~ funcName ~ "' not found", callExpr.location);
        }

        // Check if function returns a string (dynamic ubyte[])
        bool returnsString = isStringType(funcDecl.returnType);
        
        log(3, "CTFE: Calling ", funcName, " (returns string: ", returnsString, ")");
        
        // For string-returning functions, compile via backend and extract string from memory
        if (returnsString) {
            long structPtr = executeViaBackend(funcDecl, []);
            // Read {ptr, len} from the array struct in execution memory
            ubyte[] structBytes = cachedContext.readMemory(cast(uint)structPtr, 8);
            uint dataPtr = (cast(uint)structBytes[0]) |
                           (cast(uint)structBytes[1] << 8) |
                           (cast(uint)structBytes[2] << 16) |
                           (cast(uint)structBytes[3] << 24);
            uint len = (cast(uint)structBytes[4]) |
                       (cast(uint)structBytes[5] << 8) |
                       (cast(uint)structBytes[6] << 16) |
                       (cast(uint)structBytes[7] << 24);
            ubyte[] strBytes = cachedContext.readMemory(dataPtr, len);
            return CTFEResult.fromString(cast(string)strBytes.idup);
        }
        
        // Check if function returns a static array
        if (auto arrType = cast(ArrayType)funcDecl.returnType) {
            if (arrType.arraySize !is null) {
                log(3, "CTFE: Function returns static array, evaluating with hidden param");
                return evaluateStaticArrayReturningFunction(funcDecl, callExpr.arguments);
            }
        }
        
        // Check if function returns a struct (uses hidden result pointer)
        if (auto structDecl = funcDecl.returnType.asStruct()) {
            log(3, "CTFE: Function returns struct, evaluating with hidden param");
            return evaluateStructReturningFunction(funcDecl, callExpr.arguments, structDecl);
        }
        
        // Check if this is a simple function that only contains CTFE intrinsics
        if (canInterpretDirectly(funcDecl)) {
            log(3, "CTFE: Interpreting ", funcName, " directly");
            return CTFEResult.fromInt(interpretFunction(funcDecl));
        }
        
        // Check if function uses __ctfe_runtime - if so, interpret it
        if (usesCTFERuntime(funcDecl)) {
            log(3, "CTFE: Function uses __ctfe_runtime, interpreting directly");
            return interpretIntFunction(funcDecl);
        }
        
        // Check if any parameter is a struct type — needs full compilation via wrapper
        bool hasStructParam = false;
        foreach (param; funcDecl.parameters) {
            auto pt = resolveAliasType(param.type);
            if (pt.asStruct() !is null) {
                hasStructParam = true;
                break;
            }
        }

        if (hasStructParam) {
            // Struct args can't be decomposed into scalar values.
            // Wrap the call in a synthetic function and compile through the full backend.
            log(3, "CTFE: Function has struct params, using wrapper for full compilation");
            auto retStmt = new ReturnStatement(callExpr.location, callExpr);
            auto body_ = new CompoundStatement(callExpr.location, [cast(Statement)retStmt]);
            auto wrapperName = "__ctfe_eval_" ~ to!string(ctfeWrapperCounter++);
            auto wrapper = new FunctionDecl(callExpr.location, wrapperName,
                new BasicType(callExpr.location, BasicType.Kind.Int32), [], body_);
            return CTFEResult.fromInt(executeViaBackend(wrapper, []));
        }

        // Evaluate arguments (must be literals or simple expressions)
        long[] args;
        foreach (arg; callExpr.arguments) {
            args ~= extractLiteralValue(arg);
        }

        log(3, "CTFE: Calling ", funcName, " with args ", args);

        // Execute via the configured backend (WASM or Native)
        long result = executeViaBackend(funcDecl, args);

        return CTFEResult.fromInt(result);
    }
    
    /**
     * Evaluate a template instantiation call as a manifest constant.
     * e.g. enum RESULT = max!int(3, 8)
     */
    void evaluateTemplateInstantiationCall(ManifestConstantDecl manifest, TemplateInstantiationExpression tmplInst) {
        import semantic.template_instantiation : TemplateInstantiator;

        // Find the template declaration
        TemplateDecl tmplDecl = null;
        foreach (decl; allDeclarations) {
            if (auto td = cast(TemplateDecl)decl) {
                if (td.name == tmplInst.templateName) {
                    tmplDecl = td;
                    break;
                }
            }
        }
        if (!tmplDecl)
            throw new CTFEError("CTFE: Template '" ~ tmplInst.templateName ~ "' not found", tmplInst.location);

        // Instantiate the template
        auto instantiator = new TemplateInstantiator();
        auto inst = cast(FunctionDecl)instantiator.instantiate(tmplDecl, tmplInst.templateArguments);
        if (!inst)
            throw new CTFEError("CTFE: Template '" ~ tmplInst.templateName ~ "' did not produce a function", tmplInst.location);
        tmplInst.resolvedInstantiation = inst;

        // Evaluate arguments
        long[] args;
        foreach (arg; tmplInst.callArguments) {
            args ~= extractLiteralValue(arg);
        }

        log(3, "CTFE: Calling template ", inst.name, " with args ", args);

        long result = executeViaBackend(inst, args);
        manifest.ctfeValue = result;
        manifest.ctfeComplete = true;
        manifest.inferredType = new BasicType(manifest.location, BasicType.Kind.Int32);
        log(3, "CTFE: ", manifest.name, " = ", result, " (template call)");
    }

    /**
     * Evaluate a function that returns a static array at compile time.
     * Handles the hidden __result parameter by:
     * 1. Allocating memory in WASM linear memory
     * 2. Passing that address as first argument
     * 3. Reading result bytes back after call
     */
    CTFEResult evaluateStaticArrayReturningFunction(FunctionDecl funcDecl, Expression[] argExprs) {
        auto arrType = cast(ArrayType)funcDecl.returnType;
        if (!arrType || arrType.arraySize is null) {
            throw new CTFEError("Expected static array return type", funcDecl.location);
        }
        
        // Evaluate array size
        uint elemCount = 0;
        if (auto lit = cast(LiteralExpression)arrType.arraySize) {
            if (lit.value.type == typeid(long)) {
                elemCount = cast(uint)lit.value.get!long();
            } else if (lit.value.type == typeid(int)) {
                elemCount = cast(uint)lit.value.get!int();
            }
        }
        
        if (elemCount == 0) {
            throw new CTFEError("Cannot evaluate static array size", funcDecl.location);
        }
        
        uint elemSize = 4;  // Assume int elements for now
        uint totalSize = elemCount * elemSize;
        
        // Evaluate arguments
        long[] args;
        foreach (arg; argExprs) {
            args ~= extractLiteralValue(arg);
        }
        
        log(3, "CTFE: Calling ", funcDecl.name, " with args ", args, " returning ", elemCount, " elements");
        
        // Execute via backend with large return support
        auto result = executeStaticArrayViaBackend(funcDecl, args, elemCount, elemSize);
        
        return result;
    }
    
    /**
     * Execute a function that returns a static array via CTFE backend.
     */
    CTFEResult executeStaticArrayViaBackend(FunctionDecl funcDecl, long[] args, uint elemCount, uint elemSize) {
        import semantic.dependency_analyzer : DependencyAnalyzer;
        import std.algorithm : map, filter, canFind;
        import std.array : array, join;
        
        // Find all functions this one depends on (transitive closure)
        auto t0 = MonoTime.currTime;
        auto analyzer = new DependencyAnalyzer(symbolTable, allDeclarations);
        auto dependencies = analyzer.findDependencies(funcDecl);
        statAnalysisTime += MonoTime.currTime - t0;

        // Check which functions are new (not yet in context)
        auto newFuncs = dependencies.filter!(f => ctfeFuncKey(f) !in compiledFunctions).array;

        // Recompile if we have new functions
        if (!newFuncs.empty) {
            statCacheMisses++;
            statFunctionsCompiled += cast(uint)newFuncs.length;
            log(3, "CTFE: Compiling ", newFuncs.length, " new functions for ", funcDecl.name);

            // Type-check new functions (save/restore scope for re-entrancy safety)
            {
                auto saved = symbolTable.saveAndResetScope();
                scope(exit) symbolTable.restoreScope(saved);
                auto typeChecker = new TypeChecker(symbolTable);
                foreach (dep; newFuncs) {
                    try {
                        typeChecker.checkFunctionDeclaration(dep);
                    } catch (TypeError e) {
                        throw new CTFEError("CTFE type check error in " ~ dep.name ~ ": " ~ e.msg, dep.location);
                    }
                }
            }

            if (cachedContext !is null) {
                cachedContext.dispose();
                cachedContext = null;
            }

            auto t1 = MonoTime.currTime;
            auto allFuncs = contextFunctions ~ newFuncs;
            cachedContext = backend.compileWithDependencies(allFuncs, funcDecl.name);
            statCompileTime += MonoTime.currTime - t1;
            if (cachedContext is null) {
                auto errLoc = backend.errorLocation();
                throw new CTFEError("CTFE compile error: " ~ backend.error(),
                    errLoc.filename ? errLoc : funcDecl.location);
            }

            contextFunctions = allFuncs;
            foreach (f; newFuncs) {
                compiledFunctions[ctfeFuncKey(f)] = true;
            }
        } else {
            statCacheHits++;
        }

        // Execute with large return - allocate result space and prepend address to args
        uint totalSize = elemCount * elemSize;
        auto t2 = MonoTime.currTime;
        auto result = cachedContext.callWithLargeReturn(funcDecl.name, args, totalSize);
        statExecTime += MonoTime.currTime - t2;

        if (!result.success) {
            throw new CTFEError("CTFE execution error: " ~ result.error, funcDecl.location);
        }

        log(3, "CTFE: ", funcDecl.name, " returned ", result.arrayBytes.length, " bytes");
        
        // Convert bytes to array of longs
        long[] values;
        for (uint i = 0; i < result.arrayBytes.length; i += elemSize) {
            if (elemSize == 4 && i + 4 <= result.arrayBytes.length) {
                int v = (cast(int)result.arrayBytes[i]) |
                       (cast(int)result.arrayBytes[i+1] << 8) |
                       (cast(int)result.arrayBytes[i+2] << 16) |
                       (cast(int)result.arrayBytes[i+3] << 24);
                values ~= v;
            }
        }
        
        return CTFEResult.fromArray(values, result.arrayBytes);
    }
    
    /**
     * Evaluate a function that returns a struct via hidden result pointer.
     */
    CTFEResult evaluateStructReturningFunction(FunctionDecl funcDecl, Expression[] argExprs, StructDecl structDecl) {
        import semantic.dependency_analyzer : DependencyAnalyzer;
        import std.algorithm : filter;
        import std.array : array;
        
        // Evaluate arguments
        long[] args;
        foreach (arg; argExprs) {
            args ~= extractLiteralValue(arg);
        }
        
        uint structSize = cast(uint)structDecl.structSize;
        log(3, "CTFE: Calling ", funcDecl.name, " with args ", args, " returning struct of ", structSize, " bytes");
        
        // Find dependencies and compile if needed
        auto t0 = MonoTime.currTime;
        auto analyzer = new DependencyAnalyzer(symbolTable, allDeclarations);
        auto dependencies = analyzer.findDependencies(funcDecl);
        statAnalysisTime += MonoTime.currTime - t0;
        auto newFuncs = dependencies.filter!(f => ctfeFuncKey(f) !in compiledFunctions).array;

        if (!newFuncs.empty) {
            statCacheMisses++;
            statFunctionsCompiled += cast(uint)newFuncs.length;
            log(3, "CTFE: Compiling ", newFuncs.length, " new functions for ", funcDecl.name);

            // Type-check new functions (save/restore scope for re-entrancy safety)
            {
                auto saved = symbolTable.saveAndResetScope();
                scope(exit) symbolTable.restoreScope(saved);
                auto typeChecker = new TypeChecker(symbolTable);
                foreach (dep; newFuncs) {
                    try {
                        typeChecker.checkFunctionDeclaration(dep);
                    } catch (TypeError e) {
                        throw new CTFEError("CTFE type check error in " ~ dep.name ~ ": " ~ e.msg, dep.location);
                    }
                }
            }

            if (cachedContext !is null) {
                cachedContext.dispose();
                cachedContext = null;
            }

            auto t1 = MonoTime.currTime;
            auto allFuncs = contextFunctions ~ newFuncs;
            cachedContext = backend.compileWithDependencies(allFuncs, funcDecl.name);
            statCompileTime += MonoTime.currTime - t1;
            if (cachedContext is null) {
                auto errLoc = backend.errorLocation();
                throw new CTFEError("CTFE compile error: " ~ backend.error(),
                    errLoc.filename ? errLoc : funcDecl.location);
            }

            contextFunctions = allFuncs;
            foreach (f; newFuncs) {
                compiledFunctions[ctfeFuncKey(f)] = true;
            }
        } else {
            statCacheHits++;
        }

        // Execute with large return - struct is written to result buffer
        auto t2 = MonoTime.currTime;
        auto result = cachedContext.callWithLargeReturn(funcDecl.name, args, structSize);
        statExecTime += MonoTime.currTime - t2;

        if (!result.success) {
            throw new CTFEError("CTFE execution error: " ~ result.error, funcDecl.location);
        }
        
        log(3, "CTFE: ", funcDecl.name, " returned ", result.arrayBytes.length, " bytes");
        
        // Return struct as array of field values (assuming 4-byte fields for now)
        long[] values;
        for (uint i = 0; i < result.arrayBytes.length; i += 4) {
            if (i + 4 <= result.arrayBytes.length) {
                int v = (cast(int)result.arrayBytes[i]) |
                       (cast(int)result.arrayBytes[i+1] << 8) |
                       (cast(int)result.arrayBytes[i+2] << 16) |
                       (cast(int)result.arrayBytes[i+3] << 24);
                values ~= v;
            }
        }
        
        return CTFEResult.fromStruct(values, result.arrayBytes);
    }
    
    /**
     * Evaluate a function call at compile time
     * Returns 0 for void functions (legacy - use evaluateCallExpressionString for new code)
     */
    long evaluateCallExpression(CallExpression callExpr) {
        auto result = evaluateCallExpressionString(callExpr);
        if (result.isString) {
            throw new CTFEError("CTFE: Expected integer result but got string", callExpr.location);
        }
        return result.intValue;
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
            if (returnStmt.value) return expressionUsesCTFERuntime(returnStmt.value);
            return false;
        }
        if (auto ifStmt = cast(IfStatement)stmt) {
            if (statementUsesCTFERuntime(ifStmt.thenStatement)) return true;
            if (ifStmt.elseStatement && statementUsesCTFERuntime(ifStmt.elseStatement)) return true;
            return false;
        }
        if (auto whileStmt = cast(WhileStatement)stmt) {
            return statementUsesCTFERuntime(whileStmt.body_);
        }
        if (auto forStmt = cast(ForStatement)stmt) {
            if (forStmt.init && statementUsesCTFERuntime(forStmt.init)) return true;
            if (forStmt.body_ && statementUsesCTFERuntime(forStmt.body_)) return true;
            return false;
        }
        if (cast(BreakStatement)stmt || cast(ContinueStatement)stmt
            || cast(MixinStatement)stmt || cast(StructDeclarationStatement)stmt) {
            return false;
        }
        assert(0, "statementUsesCTFERuntime: unhandled statement type: " ~ typeid(stmt).name);
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
        log(3, "CTFE: Interpreting int function ", funcDecl.name);
        
        if (!funcDecl.body_) {
            throw new CTFEError("CTFE: Function '" ~ funcDecl.name ~ "' has no body", funcDecl.location);
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
        
        throw new CTFEError("CTFE: Function '" ~ funcDecl.name ~ "' did not return a value", funcDecl.location);
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
                    log(3, "CTFE: Local '", varDecl.name, "' = ", value);
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
            throw new CTFEError("CTFE: Undefined identifier '" ~ ident.name ~ "'", expr.location);
        }
        
        // Call expression (including __ctfe_runtime calls)
        if (auto call = cast(CallExpression)expr) {
            auto result = evaluateCallExpressionString(call);
            if (result.isString) {
                throw new CTFEError("CTFE: Expected integer but got string", expr.location);
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
                case BinaryExpression.Operator.UnsignedShiftRight: return left >>> right;
                case BinaryExpression.Operator.Concat:
                    throw new CTFEError("CTFE: String concat not supported in numeric context", expr.location);
            }
        }

        throw new CTFEError("CTFE: Cannot evaluate expression at compile time: " ~ expr.toString(), expr.location);
    }
    
    /// Resolve transparent type aliases via the symbol table's alias registry.
    private Type resolveAliasType(Type type) {
        if (auto ut = cast(UserType)type) {
            auto target = symbolTable.lookupAlias(ut.name);
            if (target) {
                return resolveAliasType(target);
            }
        }
        return type;
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
                    if (ident.name == "__writeln") return true;
                }
            }
            return false;
        }
        if (auto returnStmt = cast(ReturnStatement)stmt) {
            return returnStmt.value is null;
        }
        // Any other statement type means this isn't a pure-intrinsic function
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
        } else {
            assert(0, "interpretStatement: unhandled statement type: " ~ typeid(stmt).name);
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
                    long val = extractLiteralValue(arg);
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
     * Extract a literal value directly from an AST node.
     * Only handles bare literals — not interpretation.
     * For non-literal expressions, falls back to evaluateExpressionViaBackend.
     */
    long extractLiteralValue(Expression expr) {
        if (auto literal = cast(LiteralExpression)expr) {
            if (literal.value.type == typeid(long)) {
                return literal.value.get!long();
            }
            if (literal.value.type == typeid(bool)) {
                return literal.value.get!bool() ? 1 : 0;
            }
            if (literal.value.type == typeid(char)) {
                return cast(long)literal.value.get!char();
            }
        }
        // For identifier references to manifest constants
        if (auto ident = cast(IdentifierExpression)expr) {
            foreach (decl; allDeclarations) {
                if (auto manifest = cast(ManifestConstantDecl)decl) {
                    if (manifest.name == ident.name) {
                        if (!manifest.ctfeComplete)
                            evaluateManifestConstant(manifest);
                        if (manifest.ctfeComplete && !manifest.isStringType && !manifest.isArrayType)
                            return manifest.ctfeValue;
                    }
                }
            }
        }
        // Non-literal: evaluate through the backend
        return evaluateExpressionViaBackend(expr);
    }

    /**
     * Evaluate an integer expression by compiling it to WASM and executing.
     * Routes through the real backend for proper error handling.
     */
    long evaluateExpressionViaBackend(Expression expr) {
        import semantic.ctfe_runtime : CTFERuntime, CTFERuntimeError;

        ensureDependenciesEvaluated(expr);

        auto emitter = new BinaryEmitter(symbolTable, enableStackTrace);
        ubyte[] wasmBytes = emitter.emitIntExpressionModule(expr);
        if (wasmBytes is null) {
            auto errLoc = emitter.errorLocation();
            throw new CTFEError("CTFE compile error: " ~ emitter.error(),
                errLoc.filename ? errLoc : expr.location);
        }

        auto runtime = new CTFERuntime();
        scope(exit) destroy(runtime);

        try {
            runtime.loadModule(wasmBytes);
            auto result = runtime.callI32("__eval");
            return result.asInt();
        } catch (CTFERuntimeError e) {
            throw new CTFEError("CTFE execution error: " ~ e.msg, expr.location);
        }
    }
    
    /**
     * Execute a function via the configured backend.
     * This is the new unified path that works with both WASM and Native backends.
     */
    long executeViaBackend(FunctionDecl funcDecl, long[] args) {
        import semantic.dependency_analyzer : DependencyAnalyzer;
        import std.algorithm : map, filter, canFind;
        import std.array : array, join;

        // Expand any mixin statements in function body before compilation
        expandFunctionMixins(funcDecl);

        // Find all functions this one depends on (transitive closure)
        auto t0 = MonoTime.currTime;
        auto analyzer = new DependencyAnalyzer(symbolTable, allDeclarations);
        auto dependencies = analyzer.findDependencies(funcDecl);
        statAnalysisTime += MonoTime.currTime - t0;

        // Track call count
        statCallCount++;

        // Check which functions are new (not yet in context)
        auto newFuncs = dependencies.filter!(f => ctfeFuncKey(f) !in compiledFunctions).array;
        bool needsRecompile = newFuncs.length > 0;

        if (needsRecompile) {
            statCacheMisses++;
            statFunctionsCompiled += cast(uint)newFuncs.length;
            log(3, "CTFE: ", funcDecl.name, " needs: [",
                dependencies.map!(f => f.name).array.join(", "), "]");
            log(3, "CTFE: Adding ", newFuncs.length, " new function(s): [",
                newFuncs.map!(f => f.name).array.join(", "), "]");

            // Type-check only new functions (save/restore scope for re-entrancy safety)
            {
                auto saved = symbolTable.saveAndResetScope();
                scope(exit) symbolTable.restoreScope(saved);
                auto typeChecker = new TypeChecker(symbolTable);
                foreach (dep; newFuncs) {
                    try {
                        typeChecker.checkFunctionDeclaration(dep);
                    } catch (TypeError e) {
                        throw new CTFEError("CTFE type check error in " ~ dep.name ~ ": " ~ e.msg, dep.location);
                    }
                }
            }

            // Dispose old context and recompile with all functions (old + new)
            if (cachedContext !is null) {
                cachedContext.dispose();
                cachedContext = null;
            }

            auto t1 = MonoTime.currTime;
            auto allFuncs = contextFunctions ~ newFuncs;
            cachedContext = backend.compileWithDependencies(allFuncs, funcDecl.name);
            statCompileTime += MonoTime.currTime - t1;
            if (cachedContext is null) {
                auto errLoc = backend.errorLocation();
                throw new CTFEError("CTFE compile error: " ~ backend.error(),
                    errLoc.filename ? errLoc : funcDecl.location);
            }

            // Only mark as compiled after successful compilation
            contextFunctions = allFuncs;
            foreach (f; newFuncs) {
                compiledFunctions[ctfeFuncKey(f)] = true;
            }
        } else {
            statCacheHits++;
            log(3, "CTFE: Reusing cached context for ", funcDecl.name);
        }

        // Execute - use callByName to call any function in the context
        auto t2 = MonoTime.currTime;
        auto result = cachedContext.callByName(funcDecl.name, args);
        statExecTime += MonoTime.currTime - t2;
        if (!result.success) {
            throw new CTFEError("CTFE execution error: " ~ result.error, funcDecl.location);
        }

        log(3, "CTFE [", backend.name, "]: ", funcDecl.name, "(", args, ") = ", result.intValue);
        return result.intValue;
    }
    
    /**
     * Expand mixin statements inside a function body before compilation.
     * The mixin expander's third pass may not have run yet when CTFE needs
     * to compile a function (e.g., during top-level mixin expansion).
     */
    private void expandFunctionMixins(FunctionDecl funcDecl) {
        if (!funcDecl.body_) return;
        auto compound = cast(CompoundStatement)funcDecl.body_;
        if (!compound) return;

        // Check if any mixin statements need expansion
        bool hasMixins = false;
        foreach (stmt; compound.statements) {
            if (cast(MixinStatement)stmt) {
                hasMixins = true;
                break;
            }
        }
        if (!hasMixins) return;

        import parser.tree_sitter_bridge : TreeSitterBridge;

        // Expand mixin statements, replacing them with parsed statements
        Statement[] expanded;
        foreach (stmt; compound.statements) {
            if (auto mixinStmt = cast(MixinStatement)stmt) {
                // Evaluate the mixin expression to get a string
                string code = evaluateMixinExpressionForExpansion(mixinStmt.mixinExpr);
                log(3, "CTFE: Expanding mixin in ", funcDecl.name, ": \"", code, "\"");

                // Parse the string as statements
                string wrappedCode = "void __mixin_wrapper() { " ~ code ~ " }";
                auto bridge = new TreeSitterBridge("(ctfe-mixin)", wrappedCode);
                Declaration[] parsed = bridge.parseSourceFile();

                if (parsed.length > 0) {
                    if (auto fd = cast(FunctionDecl)parsed[0]) {
                        if (auto body_ = cast(CompoundStatement)fd.body_) {
                            expanded ~= body_.statements;
                            continue;
                        }
                    }
                }
                throw new CTFEError("CTFE: Failed to parse mixin statement: \"" ~ code ~ "\"", mixinStmt.location);
            } else {
                expanded ~= stmt;
            }
        }

        funcDecl.body_ = new CompoundStatement(compound.location, expanded);
    }

    /**
     * Evaluate a mixin expression to a string for expansion.
     * Handles string literals, identifiers (manifest constants), and concatenation.
     */
    private string evaluateMixinExpressionForExpansion(Expression expr) {
        if (auto literal = cast(LiteralExpression)expr) {
            if (literal.value.type == typeid(string)) {
                return literal.value.get!string();
            }
        }

        if (auto ident = cast(IdentifierExpression)expr) {
            foreach (decl; allDeclarations) {
                if (auto manifest = cast(ManifestConstantDecl)decl) {
                    if (manifest.name == ident.name && manifest.ctfeComplete && manifest.isStringType) {
                        return manifest.ctfeStringValue;
                    }
                }
            }
            throw new CTFEError("CTFE: Cannot evaluate mixin expression identifier '" ~ ident.name ~ "'", expr.location);
        }

        if (auto binary = cast(BinaryExpression)expr) {
            if (binary.operator == BinaryExpression.Operator.Concat) {
                return evaluateMixinExpressionForExpansion(binary.left) ~
                       evaluateMixinExpressionForExpansion(binary.right);
            }
        }

        throw new CTFEError("CTFE: Cannot evaluate mixin expression: " ~ expr.toString(), expr.location);
    }

    /**
     * Compile a single function to WASM bytes
     * @deprecated Use executeViaBackend instead
     */
    ubyte[] compileFunctionToWasm(FunctionDecl funcDecl) {
        // Ensure the function is type-checked before compilation
        // This is necessary because CTFE may run before the main type-checking pass
        // (e.g., when evaluating manifest constants during mixin expansion)
        // Save/restore scope for re-entrancy safety
        {
            auto saved = symbolTable.saveAndResetScope();
            scope(exit) symbolTable.restoreScope(saved);
            auto typeChecker = new TypeChecker(symbolTable);
            try {
                typeChecker.checkFunctionDeclaration(funcDecl);
            } catch (TypeError e) {
                log(3, "CTFE type check error: ", e.msg);
                return null;
            }
        }

        // Create a minimal compilation with just this function
        auto emitter = new BinaryEmitter(symbolTable, enableStackTrace);
        auto result = emitter.emit([funcDecl]);

        if (result is null) {
            log(3, "CTFE compile error: ", emitter.error());
        }
        
        return result;
    }
    
    /**
     * Execute WASM with embedded wasm3 runtime and return result
     */
    long executeWasm(ubyte[] wasmBytes, string funcName, long[] args) {
        import semantic.ctfe_runtime : CTFERuntime, CTFERuntimeError;
        
        log(3, "CTFE: Executing ", funcName, " via embedded wasm3");
        
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
            log(3, "CTFE: Result = ", result.asInt());
            return result.asInt();
            
        } catch (CTFERuntimeError e) {
            throw new CTFEError("CTFE: wasm3 execution failed: " ~ e.msg, SourceLocation.init);
        }
    }
}
