/**
 * Backend Interface for Code Generation
 * 
 * This module defines the abstract interface that all code generation backends
 * must implement. This allows swapping between WASM and Native backends.
 * 
 * The key abstraction is at the function compilation level:
 * - Compile a function declaration to executable form
 * - Execute the compiled function with arguments
 * - Clean up resources when done
 */
module codegen.backend;

import ast.nodes : Declaration, FunctionDecl, StructDecl, SourceLocation;
import ast.expressions;
import semantic.symbol_table;

// Re-export backend implementations for convenience
public import codegen.native.backend : NativeBackend, NativeCompiledFunction;
public import codegen.wasm.backend : WASMBackend, WASMCompiledFunction;

/// A single call stack frame for exception trace reporting.
struct CallStackFrame {
    string funcName;
    string fileName;
    uint line;
    uint column;
}

/**
 * Result of compiling and executing a function
 */
struct ExecutionResult {
    bool success;
    long intValue;
    string stringValue;
    ubyte[] arrayBytes;
    string error;
    int throwLine;
    int throwCol;
    CallStackFrame[] callStack;

    static ExecutionResult fromInt(long v) {
        return ExecutionResult(true, v);
    }

    static ExecutionResult fromString(string s) {
        ExecutionResult r;
        r.success = true;
        r.stringValue = s;
        return r;
    }

    static ExecutionResult fromArray(ubyte[] bytes) {
        ExecutionResult r;
        r.success = true;
        r.arrayBytes = bytes;
        return r;
    }

    static ExecutionResult failure(string err, int line = 0, int col = 0) {
        ExecutionResult r;
        r.error = err;
        r.throwLine = line;
        r.throwCol = col;
        return r;
    }
}

/**
 * A compiled function that can be executed.
 * 
 * Backends return this from compile(), and the caller can invoke it
 * multiple times with different arguments before disposing.
 */
interface CompiledFunction {
    /// Execute the function with the given arguments
    ExecutionResult call(long[] args);
    
    /// Execute a specific function by name (for multi-function contexts)
    ExecutionResult callByName(string funcName, long[] args);
    
    /// Execute a function that returns a large value (struct or static array)
    /// via hidden __result parameter. The resultSize bytes are allocated,
    /// address is prepended to args, and result bytes are read back.
    ExecutionResult callWithLargeReturn(string funcName, long[] args, uint resultSize);
    
    /// Read bytes from the execution memory (WASM linear memory or native address space)
    ubyte[] readMemory(ulong offset, uint length);

    /// Check if a function exists in this compiled context
    bool hasFunction(string funcName);
    
    /// Release any resources (native memory, runtime state, etc.)
    void dispose();
    
    /// Get the function name (for debugging)
    string name();
}

/**
 * Abstract backend for code generation.
 * 
 * Implementations:
 * - WASMBackend: Compiles to WASM, executes via wasm3 (codegen.wasm.backend)
 * - NativeBackend: Compiles to ARM64, executes directly (codegen.native.backend)
 */
interface Backend {
    /**
     * Compile a single function to executable form.
     * 
     * The returned CompiledFunction can be called multiple times.
     * Caller is responsible for calling dispose() when done.
     */
    CompiledFunction compile(FunctionDecl func);
    
    /**
     * Compile multiple functions together with a designated entry point.
     * All functions can call each other directly (no trampoline).
     * 
     * Used for CTFE where a function may call other D functions.
     * Returns a callable for the entry function.
     */
    CompiledFunction compileWithDependencies(FunctionDecl[] funcs, string entryFuncName);
    
    /**
     * Compile multiple declarations (for full module compilation).
     * Returns raw bytes (WASM binary or native object, depending on backend).
     * Returns null on failure.
     */
    ubyte[] compileModule(Declaration[] decls);
    
    /**
     * Get the last error message, if any.
     */
    string error();

    /**
     * Get the source location of the last error, if available.
     */
    SourceLocation errorLocation();

    /**
     * Backend name for debugging/logging.
     */
    string name();
}

/**
 * Backend factory - creates the appropriate backend based on configuration.
 * 
 * Params:
 *   backendName = "wasm" or "native" (auto-detects architecture)
 *   symbolTable = Symbol table for lookups
 *   enableStackTrace = Emit call stack tracking for CTFE errors (default: true)
 */
Backend createBackend(string backendName, SymbolTable symbolTable, bool enableStackTrace = true) {
    import codegen.native.codegen_interface : hostArchitecture;
    
    switch (backendName) {
        case "wasm":
            return new WASMBackend(symbolTable, enableStackTrace);
        
        case "native":
            // Auto-detect host architecture
            string arch = hostArchitecture();
            switch (arch) {
                case "arm64":
                    return new NativeBackend(symbolTable, enableStackTrace);
                
                case "x86_64":
                    throw new Exception(
                        "Native backend not yet implemented for x86_64. " ~
                        "Use --backend=wasm or contribute x86_64 support!");
                
                default:
                    throw new Exception(
                        "Native backend not supported on architecture: " ~ arch ~ ". " ~
                        "Use --backend=wasm instead.");
            }
        
        // Allow explicit architecture selection for testing/development
        case "native-arm64":
            return new NativeBackend(symbolTable, enableStackTrace);
        
        // Future: case "native-x86_64": return new X86_64NativeBackend(symbolTable);
        
        default:
            throw new Exception("Unknown backend: " ~ backendName);
    }
}
