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
import ast.expressions;
import semantic.symbol_table;
import codegen.emitter;
import codegen.wasm;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.conv;
import std.format;
import std.array;

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
     * Evaluate a function call at compile time
     */
    long evaluateCallExpression(CallExpression callExpr) {
        // Get the function name
        auto identExpr = cast(IdentifierExpression)callExpr.function_;
        if (!identExpr) {
            throw new CTFEError("CTFE: Indirect function calls not supported");
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
     * Execute WASM with wasm3 and return result
     */
    long executeWasm(ubyte[] wasmBytes, string funcName, long[] args) {
        // Write WASM to temp file
        string tempDir = tempDir();
        string wasmPath = buildPath(tempDir, "ctfe_temp.wasm");
        std.file.write(wasmPath, wasmBytes);
        
        scope(exit) {
            if (exists(wasmPath)) {
                remove(wasmPath);
            }
        }
        
        // Build wasm3 command
        string[] cmd = ["wasm3", "--func", funcName, wasmPath];
        foreach (arg; args) {
            cmd ~= to!string(arg);
        }
        
        writeln("CTFE: Running ", cmd);
        
        // Execute
        auto result = execute(cmd);
        
        if (result.status != 0) {
            throw new CTFEError("CTFE: wasm3 execution failed: " ~ result.output);
        }
        
        // Parse result from output like "Result: 42"
        string output = result.output.strip();
        writeln("CTFE: wasm3 output: ", output);
        
        auto resultMatch = output.indexOf("Result:");
        if (resultMatch == -1) {
            throw new CTFEError("CTFE: Could not parse wasm3 output: " ~ output);
        }
        
        string valueStr = output[resultMatch + 7 .. $].strip();
        return to!long(valueStr);
    }
}
