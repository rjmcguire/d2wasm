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

import ast.nodes;
import ast.expressions;
import semantic.symbol_table;

/**
 * Result of compiling and executing a function
 */
struct ExecutionResult {
    bool success;
    long intValue;
    string stringValue;
    ubyte[] arrayBytes;
    string error;
    
    static ExecutionResult fromInt(long v) {
        return ExecutionResult(true, v, null, null, null);
    }
    
    static ExecutionResult fromString(string s) {
        return ExecutionResult(true, 0, s, null, null);
    }
    
    static ExecutionResult fromArray(ubyte[] bytes) {
        return ExecutionResult(true, 0, null, bytes, null);
    }
    
    static ExecutionResult failure(string err) {
        return ExecutionResult(false, 0, null, null, err);
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
    
    /// Release any resources (native memory, runtime state, etc.)
    void dispose();
    
    /// Get the function name (for debugging)
    string name();
}

/**
 * Abstract backend for code generation.
 * 
 * Implementations:
 * - WASMBackend: Compiles to WASM, executes via wasm3
 * - NativeBackend: Compiles to ARM64, executes directly
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
     * Backend name for debugging/logging.
     */
    string name();
}

/**
 * Backend factory - creates the appropriate backend based on configuration.
 */
Backend createBackend(string backendName, SymbolTable symbolTable) {
    switch (backendName) {
        case "wasm":
            return new WASMBackend(symbolTable);
        case "native":
            return new NativeBackend(symbolTable);
        default:
            throw new Exception("Unknown backend: " ~ backendName);
    }
}

/**
 * Native Backend - compiles to ARM64 machine code via copy-and-patch
 */
class NativeBackend : Backend {
    import codegen.native.arm64_codegen;
    import codegen.native.stencil_table;
    import semantic.type_checker;
    
    private SymbolTable symbolTable;
    private string lastError;
    
    this(SymbolTable st) {
        this.symbolTable = st;
    }
    
    override CompiledFunction compile(FunctionDecl func) {
        // Type-check first
        auto typeChecker = new TypeChecker(symbolTable);
        try {
            typeChecker.checkFunctionDeclaration(func);
        } catch (Exception e) {
            lastError = "Type check error: " ~ e.msg;
            return null;
        }
        
        try {
            return new NativeCompiledFunction(func, symbolTable);
        } catch (Exception e) {
            lastError = "Native compile error: " ~ e.msg;
            return null;
        }
    }
    
    override CompiledFunction compileWithDependencies(FunctionDecl[] funcs, string entryFuncName) {
        // Type-check all functions first
        auto typeChecker = new TypeChecker(symbolTable);
        foreach (func; funcs) {
            try {
                typeChecker.checkFunctionDeclaration(func);
            } catch (Exception e) {
                lastError = "Type check error in " ~ func.name ~ ": " ~ e.msg;
                return null;
            }
        }
        
        try {
            return new NativeCompiledFunction(funcs, entryFuncName, symbolTable);
        } catch (Exception e) {
            lastError = "Native compile error: " ~ e.msg;
            return null;
        }
    }
    
    override ubyte[] compileModule(Declaration[] decls) {
        // Native backend doesn't produce portable binary output (yet)
        // For now, only supports single-function CTFE compilation
        lastError = "Native backend does not support module compilation";
        return null;
    }
    
    override string error() { return lastError; }
    override string name() { return "native"; }
}

/**
 * Native compiled function - executes ARM64 code directly
 */
class NativeCompiledFunction : CompiledFunction {
    import codegen.native.arm64_codegen;
    import codegen.native.stencil_table;
    import ast.nodes;
    import ast.statements;
    import ast.expressions;
    import semantic.symbol_table : SymbolKind;
    alias ArrayType = ast.nodes.ArrayType;
    
    private string funcName;
    private NativeCodeGen gen;  // renamed from codegen to avoid module name collision
    private size_t entryPoint;
    private size_t paramCount;           // number of function parameters
    private SymbolTable symbolTable;     // for looking up struct types
    
    // Local variable tracking
    private uint[string] localOffsets;  // variable name → stack offset
    private StructDecl[string] localStructTypes;  // variable name → struct type (if struct)
    private uint nextLocalOffset;        // next available stack slot
    private uint totalLocalBytes;        // total stack space needed
    private uint tempSlot;               // stack offset for expression temporaries
    
    // For return statements to jump to
    import codegen.native.arm64_codegen : Label;
    private Label epilogueLabel;
    
    // For multi-function support: map function names to their labels
    private Label[string] functionLabels;
    private FunctionDecl[string] functionDecls;  // for looking up parameter counts
    
    /// Single function constructor (original)
    this(FunctionDecl func, SymbolTable st) {
        import std.stdio : writeln;
        
        this.funcName = func.name;
        this.symbolTable = st;
        this.gen = NativeCodeGen.alloc(64 * 1024);  // 64KB code buffer
        
        if (!gen.base) {
            throw new Exception("Failed to allocate executable memory");
        }
        
        // Store parameter count for call()
        this.paramCount = func.parameters.length;
        
        // Compile the function
        compileFunction(func);
        
        // Finalize (resolve branches, make executable)
        if (!gen.finalize()) {
            throw new Exception("Failed to finalize native code");
        }
    }
    
    /// Multi-function constructor for CTFE with dependencies
    this(FunctionDecl[] funcs, string entryFuncName, SymbolTable st) {
        import std.stdio : writeln;
        
        this.funcName = entryFuncName;
        this.symbolTable = st;
        this.gen = NativeCodeGen.alloc(64 * 1024);  // 64KB code buffer
        
        if (!gen.base) {
            throw new Exception("Failed to allocate executable memory");
        }
        
        // Store all function decls for call resolution
        foreach (func; funcs) {
            functionDecls[func.name] = func;
        }
        
        // Create labels for all functions before compiling any
        foreach (func; funcs) {
            functionLabels[func.name] = gen.newLabel();
        }
        
        // Find entry function and store its param count
        if (auto entryFunc = entryFuncName in functionDecls) {
            this.paramCount = (*entryFunc).parameters.length;
        }
        
        // Compile all functions
        foreach (func; funcs) {
            compileFunction(func);
        }
        
        // Set entry point to the entry function
        if (auto entryLabel = entryFuncName in functionLabels) {
            entryPoint = (*entryLabel).offset;
        }
        
        // Finalize (resolve branches, make executable)
        if (!gen.finalize()) {
            throw new Exception("Failed to finalize native code");
        }
    }
    
    private void compileFunction(FunctionDecl func) {
        import std.stdio : writeln;
        
        // Bind function label (for multi-function mode)
        if (auto labelPtr = func.name in functionLabels) {
            gen.bindLabel(*labelPtr);
        }
        
        // For single-function mode, track entry point
        if (functionLabels.length == 0) {
            entryPoint = gen.pos;
        }
        
        // Reset local tracking for this function
        localOffsets.clear();
        localStructTypes.clear();
        nextLocalOffset = 0;
        
        // Reserve space for parameters first (they come in registers x0-x7)
        foreach (param; func.parameters) {
            localOffsets[param.name] = nextLocalOffset;
            nextLocalOffset += 4;  // 4 bytes per int (32-bit for now)
        }
        
        // Count bytes needed for locals in the body
        uint bodyLocalBytes = countLocalBytesInStatement(func.body_);
        
        // Reserve extra space for expression temporaries (8 bytes for temp slot)
        uint tempSlotOffset = nextLocalOffset + bodyLocalBytes;
        tempSlot = tempSlotOffset;  // Store for use in compileExpression
        uint totalNeeded = tempSlotOffset + 8;  // 8 bytes for temp
        totalLocalBytes = (totalNeeded + 15) & ~15;  // 16-byte aligned
        
        // Create epilogue label for return statements
        epilogueLabel = gen.newLabel();
        
        // Emit prologue
        if (totalLocalBytes > 0) {
            gen.emitPrologueWithLocals(totalLocalBytes);
        } else {
            gen.emitPrologue();
        }
        
        // Spill parameters from registers to stack
        // ARM64 calling convention: first 8 args in x0-x7
        foreach (i, param; func.parameters) {
            if (i >= 4) {
                throw new Exception("Native backend: more than 4 parameters not yet supported");
            }
            // Store parameter register to its stack slot
            uint offset = localOffsets[param.name];
            switch (i) {
                case 0: gen.emitStoreLocal32(offset); break;        // x0
                case 1: gen.emitStoreLocal32FromX1(offset); break;  // x1
                case 2: gen.emitStoreLocal32FromX2(offset); break;  // x2
                case 3: gen.emitStoreLocal32FromX3(offset); break;  // x3
                default: break;
            }
        }
        
        // Compile body
        if (func.body_) {
            compileStatement(func.body_);
        }
        
        // Bind epilogue label - return statements jump here
        gen.bindLabel(epilogueLabel);
        
        // Emit epilogue
        if (totalLocalBytes > 0) {
            gen.emitEpilogueWithLocals(totalLocalBytes);
        } else {
            gen.emitEpilogue();
        }
    }
    
    /**
     * Count bytes needed for locals in a statement (not just count of vars)
     */
    private uint countLocalBytesInStatement(Statement stmt) {
        if (stmt is null) return 0;
        
        uint bytes = 0;
        
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                bytes += countLocalBytesInStatement(s);
            }
        } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
            // Check type to determine size
            if (auto userType = cast(UserType)varDecl.type) {
                if (auto sd = cast(StructDecl)userType.declaration) {
                    bytes = cast(uint)sd.structSize;
                } else {
                    bytes = 4;
                }
            } else if (auto arrType = cast(ArrayType)varDecl.type) {
                if (arrType.arraySize is null) {
                    // Slice: 16 bytes for struct (64-bit ptr) + data
                    bytes = 16;
                    // Add data size if initialized with literal
                    if (auto arrLit = cast(ArrayLiteralExpression)varDecl.initializer) {
                        bytes += cast(uint)(arrLit.elements.length * 4);
                    }
                } else {
                    bytes = 4;  // Fixed array pointer?
                }
            } else {
                bytes = 4;  // int, bool, etc.
            }
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            bytes += countLocalBytesInStatement(ifStmt.thenStatement);
            bytes += countLocalBytesInStatement(ifStmt.elseStatement);
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            bytes += countLocalBytesInStatement(whileStmt.body_);
        }
        
        return bytes;
    }
    
    private void compileStatement(Statement stmt) {
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                compileStatement(s);
            }
        } else if (auto ret = cast(ReturnStatement)stmt) {
            if (ret.value) {
                compileExpression(ret.value);
            }
            // Jump to epilogue (which will restore stack and return)
            gen.emitBranch(epilogueLabel);
        } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
            compileExpression(exprStmt.expression);
        } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
            // Check if this is a struct type or slice type
            StructDecl structType = null;
            bool isSlice = false;
            uint varSize = 4;  // default to 4 bytes for int
            
            if (auto userType = cast(UserType)varDecl.type) {
                if (auto sd = cast(StructDecl)userType.declaration) {
                    structType = sd;
                    varSize = cast(uint)sd.structSize;
                }
            } else if (auto arrType = cast(ArrayType)varDecl.type) {
                if (arrType.arraySize is null) {
                    // Dynamic array (slice) = 16 bytes on native (64-bit ptr)
                    isSlice = true;
                    varSize = 16;
                    // Add data size if initialized with literal
                    if (auto arrLit = cast(ArrayLiteralExpression)varDecl.initializer) {
                        varSize += cast(uint)(arrLit.elements.length * 4);
                    }
                }
            }
            
            // Allocate stack slot for this variable
            localOffsets[varDecl.name] = nextLocalOffset;
            if (structType) {
                localStructTypes[varDecl.name] = structType;
            }
            
            // Compile initializer if present
            if (varDecl.initializer) {
                if (structType) {
                    // Struct initialization
                    if (auto call = cast(CallExpression)varDecl.initializer) {
                        if (auto funcIdent = cast(IdentifierExpression)call.function_) {
                            auto symbol = symbolTable.lookupSymbol(funcIdent.name);
                            if (symbol && symbol.kind == SymbolKind.Type) {
                                if (auto ut = cast(UserType)symbol.type) {
                                    if (auto sd = cast(StructDecl)ut.declaration) {
                                        // Initialize struct fields directly at our variable's location
                                        for (size_t i = 0; i < sd.fields.length && i < call.arguments.length; i++) {
                                            auto field = sd.fields[i];
                                            uint fieldOffset = nextLocalOffset + cast(uint)field.offset;
                                            compileExpression(call.arguments[i]);
                                            gen.emitStoreLocal32(fieldOffset);
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else if (isSlice) {
                    // Slice initialization from array literal
                    if (auto arrLit = cast(ArrayLiteralExpression)varDecl.initializer) {
                        compileSliceInit(nextLocalOffset, arrLit);
                    } else {
                        throw new Exception("Slice can only be initialized from array literal");
                    }
                } else {
                    compileExpression(varDecl.initializer);
                    gen.emitStoreLocal32(nextLocalOffset);
                }
            }
            
            nextLocalOffset += varSize;
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            // Compile: if (cond) { then } else { else }
            auto elseLabel = gen.newLabel();
            auto endLabel = gen.newLabel();
            
            // Compile condition (result in x0)
            compileExpression(ifStmt.condition);
            
            // Branch to else if condition is zero
            gen.emitBranchIfZero(elseLabel);
            
            // Compile then branch
            compileStatement(ifStmt.thenStatement);
            
            if (ifStmt.elseStatement) {
                // Jump over else branch
                gen.emitBranch(endLabel);
            }
            
            // Else branch (or just the end if no else)
            gen.bindLabel(elseLabel);
            if (ifStmt.elseStatement) {
                compileStatement(ifStmt.elseStatement);
            }
            
            gen.bindLabel(endLabel);
            
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            // Compile: while (cond) { body }
            auto loopStart = gen.newLabel();
            auto loopEnd = gen.newLabel();
            
            // Loop start
            gen.bindLabel(loopStart);
            
            // Compile condition (result in x0)
            compileExpression(whileStmt.condition);
            
            // Exit loop if condition is zero
            gen.emitBranchIfZero(loopEnd);
            
            // Compile body
            compileStatement(whileStmt.body_);
            
            // Jump back to start
            gen.emitBranch(loopStart);
            
            // Loop end
            gen.bindLabel(loopEnd);
        }
        // TODO: for
    }
    
    /// Check if an expression contains a function call (which would clobber registers)
    private bool containsFunctionCall(Expression expr) {
        if (expr is null) return false;
        
        if (cast(CallExpression)expr) {
            // Check if it's a struct construction (not a real function call)
            if (auto call = cast(CallExpression)expr) {
                if (auto funcIdent = cast(IdentifierExpression)call.function_) {
                    auto symbol = symbolTable.lookupSymbol(funcIdent.name);
                    if (symbol && symbol.kind == SymbolKind.Type) {
                        return false;  // Struct construction, not a function call
                    }
                }
            }
            return true;
        }
        
        if (auto binary = cast(BinaryExpression)expr) {
            return containsFunctionCall(binary.left) || containsFunctionCall(binary.right);
        }
        if (auto unary = cast(UnaryExpression)expr) {
            return containsFunctionCall(unary.operand);
        }
        if (auto index = cast(IndexExpression)expr) {
            return containsFunctionCall(index.array) || containsFunctionCall(index.index);
        }
        if (auto member = cast(MemberExpression)expr) {
            return containsFunctionCall(member.object);
        }
        
        return false;
    }
    
    private void compileExpression(Expression expr) {
        import std.variant : Variant;
        
        if (auto lit = cast(LiteralExpression)expr) {
            // Handle different literal types via Variant
            if (lit.value.type == typeid(long)) {
                gen.emitImm32(stencil_load_imm32, cast(int)lit.value.get!long);
            } else if (lit.value.type == typeid(int)) {
                gen.emitImm32(stencil_load_imm32, lit.value.get!int);
            } else if (lit.value.type == typeid(bool)) {
                gen.emitImm32(stencil_load_imm32, lit.value.get!bool ? 1 : 0);
            } else {
                throw new Exception("Literal type not supported: " ~ lit.value.type.toString());
            }
        } else if (auto binOp = cast(BinaryExpression)expr) {
            // Check if left operand might clobber registers (is a function call)
            bool leftMightClobber = containsFunctionCall(binOp.left);
            
            // Compile right operand first (into x0)
            compileExpression(binOp.right);
            
            if (leftMightClobber) {
                // Save right result to temp slot (function calls clobber x0-x7)
                // Using pre-allocated temp slot instead of push/pop to avoid moving SP
                gen.emitStoreLocal32(tempSlot);  // store w0 to temp slot (32-bit)
                // Compile left operand (into x0)
                compileExpression(binOp.left);
                // Now x0 = left result
                // Save left to x8 (safe since no more calls)
                gen.emitMoveX0ToX8();  // x8 = left
                // Load right from temp slot
                gen.emitLoadLocal32(tempSlot);  // x0 = right (from temp slot)
                gen.emitMoveX0ToX1();  // x1 = right
                // Restore left from x8
                gen.emitMoveX8ToX0();  // x0 = left
            } else {
                gen.emitMoveX0ToX1();  // Move to x1
                // Compile left operand (into x0)
                compileExpression(binOp.left);
            }
            // Now x0=left, x1=right
            
            // Emit operation
            final switch (binOp.operator) {
                case BinaryExpression.Operator.Add:
                    gen.emit(stencil_add_i32);
                    break;
                case BinaryExpression.Operator.Subtract:
                    gen.emit(stencil_sub_i32);
                    break;
                case BinaryExpression.Operator.Multiply:
                    gen.emit(stencil_mul_i32);
                    break;
                case BinaryExpression.Operator.Divide:
                    gen.emit(stencil_div_i32);
                    break;
                case BinaryExpression.Operator.Modulo:
                    gen.emit(stencil_mod_i32);
                    break;
                case BinaryExpression.Operator.Equal:
                    gen.emit(stencil_eq_i32);
                    break;
                case BinaryExpression.Operator.NotEqual:
                    gen.emit(stencil_ne_i32);
                    break;
                case BinaryExpression.Operator.Less:
                    gen.emit(stencil_lt_i32);
                    break;
                case BinaryExpression.Operator.LessEqual:
                    gen.emit(stencil_le_i32);
                    break;
                case BinaryExpression.Operator.Greater:
                    gen.emit(stencil_gt_i32);
                    break;
                case BinaryExpression.Operator.GreaterEqual:
                    gen.emit(stencil_ge_i32);
                    break;
                case BinaryExpression.Operator.BitwiseAnd:
                    gen.emit(stencil_and_i32);
                    break;
                case BinaryExpression.Operator.BitwiseOr:
                    gen.emit(stencil_or_i32);
                    break;
                case BinaryExpression.Operator.BitwiseXor:
                    gen.emit(stencil_xor_i32);
                    break;
                case BinaryExpression.Operator.ShiftLeft:
                    gen.emit(stencil_shl_i32);
                    break;
                case BinaryExpression.Operator.ShiftRight:
                    gen.emit(stencil_shr_i32);
                    break;
                case BinaryExpression.Operator.LogicalAnd:
                case BinaryExpression.Operator.LogicalOr:
                case BinaryExpression.Operator.Concat:
                    throw new Exception("Operator not yet supported in native backend");
            }
        } else if (auto unaryOp = cast(UnaryExpression)expr) {
            compileExpression(unaryOp.operand);
            if (unaryOp.operator == UnaryExpression.Operator.Minus) {
                // 0 - x
                gen.emitMoveX0ToX1();
                gen.emitImm32(stencil_load_imm32, 0);
                gen.emit(stencil_sub_i32);
            } else if (unaryOp.operator == UnaryExpression.Operator.LogicalNot) {
                // x == 0
                gen.emitMoveX0ToX1();
                gen.emitImm32(stencil_load_imm32, 0);
                gen.emit(stencil_eq_i32);
            }
        } else if (auto ident = cast(IdentifierExpression)expr) {
            // Load variable from stack
            if (auto offsetPtr = ident.name in localOffsets) {
                gen.emitLoadLocal32(*offsetPtr);
            } else {
                throw new Exception("Unknown variable in native backend: " ~ ident.name);
            }
        } else if (auto assign = cast(AssignmentExpression)expr) {
            // For now, only support simple assignment to identifiers
            auto targetIdent = cast(IdentifierExpression)assign.left;
            if (targetIdent is null) {
                throw new Exception("Assignment to non-identifier not yet supported in native backend");
            }
            
            auto offsetPtr = targetIdent.name in localOffsets;
            if (offsetPtr is null) {
                throw new Exception("Unknown variable in native backend: " ~ targetIdent.name);
            }
            
            if (assign.operator == AssignmentExpression.Operator.Assign) {
                // Simple assignment: x = expr
                compileExpression(assign.right);
                gen.emitStoreLocal32(*offsetPtr);
            } else {
                // Compound assignment: x op= expr
                // First compile right side to x0
                compileExpression(assign.right);
                gen.emitMoveX0ToX1();  // x1 = right value
                
                // Load current value to x0
                gen.emitLoadLocal32(*offsetPtr);
                // Now x0 = current (left), x1 = right
                
                // Apply operation based on operator
                switch (assign.operator) {
                    case AssignmentExpression.Operator.AddAssign:
                        gen.emit(stencil_add_i32);
                        break;
                    case AssignmentExpression.Operator.SubtractAssign:
                        gen.emit(stencil_sub_i32);
                        break;
                    case AssignmentExpression.Operator.MultiplyAssign:
                        gen.emit(stencil_mul_i32);
                        break;
                    case AssignmentExpression.Operator.DivideAssign:
                        gen.emit(stencil_div_i32);
                        break;
                    case AssignmentExpression.Operator.ModuloAssign:
                        gen.emit(stencil_mod_i32);
                        break;
                    case AssignmentExpression.Operator.AndAssign:
                        gen.emit(stencil_and_i32);
                        break;
                    case AssignmentExpression.Operator.OrAssign:
                        gen.emit(stencil_or_i32);
                        break;
                    case AssignmentExpression.Operator.XorAssign:
                        gen.emit(stencil_xor_i32);
                        break;
                    case AssignmentExpression.Operator.ShiftLeftAssign:
                        gen.emit(stencil_shl_i32);
                        break;
                    case AssignmentExpression.Operator.ShiftRightAssign:
                        gen.emit(stencil_shr_i32);
                        break;
                    case AssignmentExpression.Operator.ConcatAssign:
                        throw new Exception("~= not yet supported in native backend");
                    default:
                        break;
                }
                
                // Store result back
                gen.emitStoreLocal32(*offsetPtr);
            }
            // Result of assignment is the assigned value (already in x0)
        } else if (auto call = cast(CallExpression)expr) {
            // Check if this is struct construction
            if (auto funcIdent = cast(IdentifierExpression)call.function_) {
                auto symbol = symbolTable.lookupSymbol(funcIdent.name);
                if (symbol && symbol.kind == SymbolKind.Type) {
                    if (auto userType = cast(UserType)symbol.type) {
                        if (auto structDecl = cast(StructDecl)userType.declaration) {
                            // Struct construction: allocate space and init fields
                            compileStructConstruction(structDecl, call.arguments);
                            return;
                        }
                    }
                }
                
                // Check if this is a call to a known function
                if (auto labelPtr = funcIdent.name in functionLabels) {
                    if (call.arguments.length > 4) {
                        throw new Exception("Native backend: more than 4 arguments not yet supported");
                    }
                    
                    // Compile arguments in reverse order into their target registers
                    // This avoids clobbering: compile arg3→x3, arg2→x2, arg1→x1, arg0→x0
                    for (long i = cast(long)call.arguments.length - 1; i >= 0; i--) {
                        compileExpression(call.arguments[i]);
                        // Move x0 to target register (x0 stays, others need mov)
                        switch (i) {
                            case 0: break;  // already in x0
                            case 1: gen.emitMoveX0ToX1(); break;
                            case 2: gen.emitMoveX0ToX2(); break;
                            case 3: gen.emitMoveX0ToX3(); break;
                            default: break;
                        }
                    }
                    
                    // Emit the call (BL instruction)
                    gen.emitCall(*labelPtr);
                    // Result is in x0
                    return;
                }
            }
            throw new Exception("Function calls not yet supported in native backend: " ~ 
                (cast(IdentifierExpression)call.function_ ? (cast(IdentifierExpression)call.function_).name : "unknown"));
        } else if (auto member = cast(MemberExpression)expr) {
            // Check for slice.length first
            if (member.memberName == "length") {
                if (auto ident = cast(IdentifierExpression)member.object) {
                    if (auto sliceOffset = ident.name in localOffsets) {
                        // Check if it's a slice (not a struct)
                        if (ident.name !in localStructTypes) {
                            // Native slice layout: { ptr: i64, length: i32, capacity: i32 }
                            // length is at offset 8
                            gen.emitLoadLocal32(*sliceOffset + 8);
                            return;
                        }
                    }
                }
            }
            
            // Field access: obj.field (for structs)
            auto structDecl = getStructDeclFromExpr(member.object);
            if (structDecl is null) {
                throw new Exception("Cannot determine struct type for member access");
            }
            
            auto field = structDecl.getField(member.memberName);
            if (field is null) {
                throw new Exception("Unknown field: " ~ member.memberName);
            }
            
            // For local struct variables, compute address and load field
            if (auto ident = cast(IdentifierExpression)member.object) {
                if (auto baseOffset = ident.name in localOffsets) {
                    // Load from stack: local offset + field offset
                    uint totalOffset = *baseOffset + cast(uint)field.offset;
                    gen.emitLoadLocal32(totalOffset);
                    return;
                }
            }
            
            // For other expressions (e.g., nested access), compile to get pointer
            compileExpression(member.object);
            // x0 now has pointer to struct
            uint fieldOffset = cast(uint)field.offset;
            gen.emitLoadFromPointer(fieldOffset);
        } else if (auto arrLit = cast(ArrayLiteralExpression)expr) {
            // Array literal: [1, 2, 3]
            // Allocate space for data + slice struct
            uint elemCount = cast(uint)arrLit.elements.length;
            uint dataSize = elemCount * 4;  // 4 bytes per int element
            uint sliceSize = 12;  // ptr, length, capacity
            
            uint dataOffset = nextLocalOffset;
            nextLocalOffset += dataSize;
            uint sliceOffset = nextLocalOffset;
            nextLocalOffset += sliceSize;
            
            // Initialize data elements
            foreach (i, elem; arrLit.elements) {
                compileExpression(elem);
                gen.emitStoreLocal32(dataOffset + cast(uint)(i * 4));
            }
            
            // Initialize slice struct
            // ptr = sp + dataOffset
            gen.emitLoadStackPointer();
            gen.emitMoveX0ToX1();
            gen.emitImm32(stencil_load_imm32, cast(int)dataOffset);
            gen.emit(stencil_add_i32);
            gen.emitStoreLocal32(sliceOffset);  // store ptr
            
            // length = elemCount
            gen.emitImm32(stencil_load_imm32, cast(int)elemCount);
            gen.emitStoreLocal32(sliceOffset + 4);  // store length
            
            // capacity = elemCount
            gen.emitImm32(stencil_load_imm32, cast(int)elemCount);
            gen.emitStoreLocal32(sliceOffset + 8);  // store capacity
            
            // Leave pointer to slice struct in x0
            gen.emitLoadStackPointer();
            gen.emitMoveX0ToX1();
            gen.emitImm32(stencil_load_imm32, cast(int)sliceOffset);
            gen.emit(stencil_add_i32);
            
        } else if (auto indexExpr = cast(IndexExpression)expr) {
            // Array/slice indexing: arr[i]
            // Native slice layout: { ptr: i64, length: i32, capacity: i32 }
            if (auto ident = cast(IdentifierExpression)indexExpr.array) {
                if (auto sliceOffset = ident.name in localOffsets) {
                    // Compile index first (may clobber registers)
                    compileExpression(indexExpr.index);
                    // x0 = index
                    
                    // Compute index * 4 (element size)
                    gen.emitMoveX0ToX1();  // x1 = index
                    gen.emitImm32(stencil_load_imm32, 4);  // x0 = 4
                    gen.emit(stencil_mul_i32);  // x0 = index * 4
                    gen.emitMoveX0ToX1();  // x1 = index * 4
                    
                    // Load 64-bit ptr from slice struct (offset 0)
                    gen.emitLoadLocal(*sliceOffset);  // x0 = ptr (64-bit!)
                    
                    // Compute address: ptr + index * 4
                    gen.emit(stencil_add_i32);  // x0 = ptr + index * 4
                    
                    // Load value from computed address
                    gen.emitLoadFromPointer(0);
                    return;
                }
            }
            throw new Exception("Slice indexing only supported for local variables");
        } else {
            throw new Exception("Expression type not yet supported in native backend: " ~ 
                typeid(expr).toString());
        }
    }
    
    /**
     * Compile struct construction: allocate space on stack, initialize fields
     */
    private void compileStructConstruction(StructDecl structDecl, Expression[] args) {
        // Allocate space for struct on the stack
        uint structSize = cast(uint)structDecl.structSize;
        uint structOffset = nextLocalOffset;
        nextLocalOffset += structSize;
        
        // Initialize each field from arguments
        for (size_t i = 0; i < structDecl.fields.length && i < args.length; i++) {
            auto field = structDecl.fields[i];
            uint fieldOffset = structOffset + cast(uint)field.offset;
            
            // Compile the argument value (into x0)
            compileExpression(args[i]);
            
            // Store to the field's stack location
            gen.emitStoreLocal32(fieldOffset);
        }
        
        // Leave pointer to struct in x0 (stack pointer + offset)
        // For now, we use the stack offset directly since our loads expect offsets
        // Actually, for member access to work, we need the actual pointer
        // Let's compute: x0 = sp + structOffset
        gen.emitLoadStackPointer();
        gen.emitMoveX0ToX1();
        gen.emitImm32(stencil_load_imm32, cast(int)structOffset);
        gen.emit(stencil_add_i32);
        // Now x0 = pointer to struct
    }
    
    /**
     * Compile slice initialization from array literal directly to a stack location.
     * Native slice layout: { ptr: i64, length: i32, capacity: i32 } = 16 bytes
     * (Unlike WASM which uses 32-bit pointers, native ARM64 needs 64-bit)
     */
    private void compileSliceInit(uint sliceOffset, ArrayLiteralExpression arrLit) {
        uint elemCount = cast(uint)arrLit.elements.length;
        uint dataSize = elemCount * 4;  // 4 bytes per int element
        
        // Data goes right after the 16-byte slice struct
        uint dataOffset = sliceOffset + 16;
        
        // Initialize data elements
        foreach (i, elem; arrLit.elements) {
            compileExpression(elem);
            gen.emitStoreLocal32(dataOffset + cast(uint)(i * 4));
        }
        
        // Initialize slice struct at sliceOffset
        // ptr = sp + dataOffset (64-bit pointer!)
        gen.emitLoadStackPointer();
        gen.emitMoveX0ToX1();
        gen.emitImm32(stencil_load_imm32, cast(int)dataOffset);
        gen.emit(stencil_add_i32);
        gen.emitStoreLocal(sliceOffset);  // store 64-bit ptr
        
        // length = elemCount (32-bit at offset 8)
        gen.emitImm32(stencil_load_imm32, cast(int)elemCount);
        gen.emitStoreLocal32(sliceOffset + 8);  // store length
        
        // capacity = elemCount (32-bit at offset 12)
        gen.emitImm32(stencil_load_imm32, cast(int)elemCount);
        gen.emitStoreLocal32(sliceOffset + 12);  // store capacity
    }
    
    /**
     * Get the StructDecl from an expression (for member access type resolution)
     */
    private StructDecl getStructDeclFromExpr(Expression expr) {
        // For identifier expressions, check our local struct types first
        if (auto ident = cast(IdentifierExpression)expr) {
            // Check local struct variables
            if (auto sd = ident.name in localStructTypes) {
                return *sd;
            }
            // Fall back to symbol table
            auto symbol = symbolTable.lookupSymbol(ident.name);
            if (symbol) {
                if (auto userType = cast(UserType)symbol.type) {
                    return cast(StructDecl)userType.declaration;
                }
            }
        }
        // For call expressions (struct construction), get the struct type
        if (auto call = cast(CallExpression)expr) {
            if (auto funcIdent = cast(IdentifierExpression)call.function_) {
                auto symbol = symbolTable.lookupSymbol(funcIdent.name);
                if (symbol && symbol.kind == SymbolKind.Type) {
                    if (auto userType = cast(UserType)symbol.type) {
                        return cast(StructDecl)userType.declaration;
                    }
                }
            }
        }
        return null;
    }
    
    override ExecutionResult call(long[] args) {
        // Call the compiled function with appropriate number of arguments
        // ARM64 calling convention: first 8 args in x0-x7
        long result;
        
        switch (paramCount) {
            case 0:
                alias Fn0 = extern(C) long function();
                result = (cast(Fn0)(gen.base + entryPoint))();
                break;
            case 1:
                alias Fn1 = extern(C) long function(long);
                result = (cast(Fn1)(gen.base + entryPoint))(
                    args.length > 0 ? args[0] : 0);
                break;
            case 2:
                alias Fn2 = extern(C) long function(long, long);
                result = (cast(Fn2)(gen.base + entryPoint))(
                    args.length > 0 ? args[0] : 0,
                    args.length > 1 ? args[1] : 0);
                break;
            case 3:
                alias Fn3 = extern(C) long function(long, long, long);
                result = (cast(Fn3)(gen.base + entryPoint))(
                    args.length > 0 ? args[0] : 0,
                    args.length > 1 ? args[1] : 0,
                    args.length > 2 ? args[2] : 0);
                break;
            case 4:
                alias Fn4 = extern(C) long function(long, long, long, long);
                result = (cast(Fn4)(gen.base + entryPoint))(
                    args.length > 0 ? args[0] : 0,
                    args.length > 1 ? args[1] : 0,
                    args.length > 2 ? args[2] : 0,
                    args.length > 3 ? args[3] : 0);
                break;
            default:
                throw new Exception("Native backend: too many parameters (max 4 for now)");
        }
        
        return ExecutionResult.fromInt(result);
    }
    
    override void dispose() {
        if (gen.base) {
            gen.free();
        }
    }
    
    override string name() { return funcName; }
}

/**
 * WASM Backend - wraps the existing BinaryEmitter and CTFERuntime
 */
class WASMBackend : Backend {
    import codegen.emitter : BinaryEmitter;
    
    private SymbolTable symbolTable;
    private string lastError;
    
    this(SymbolTable st) {
        this.symbolTable = st;
    }
    
    override CompiledFunction compile(FunctionDecl func) {
        auto emitter = new BinaryEmitter(symbolTable);
        auto wasmBytes = emitter.emit([func]);
        
        if (wasmBytes is null) {
            lastError = emitter.error();
            return null;
        }
        
        return new WASMCompiledFunction(func.name, wasmBytes);
    }
    
    override CompiledFunction compileWithDependencies(FunctionDecl[] funcs, string entryFuncName) {
        import std.algorithm : map;
        import std.array : array;
        
        // Convert FunctionDecl[] to Declaration[] for the emitter
        Declaration[] decls = funcs.map!(f => cast(Declaration)f).array;
        
        auto emitter = new BinaryEmitter(symbolTable);
        auto wasmBytes = emitter.emit(decls);
        
        if (wasmBytes is null) {
            lastError = emitter.error();
            return null;
        }
        
        return new WASMCompiledFunction(entryFuncName, wasmBytes);
    }
    
    override ubyte[] compileModule(Declaration[] decls) {
        auto emitter = new BinaryEmitter(symbolTable);
        auto result = emitter.emit(decls);
        if (result is null) {
            lastError = emitter.error();
        }
        return result;
    }
    
    override string error() { return lastError; }
    override string name() { return "wasm"; }
}

/**
 * WASM compiled function - uses wasm3 for execution
 */
class WASMCompiledFunction : CompiledFunction {
    import semantic.ctfe_runtime : CTFERuntime, CTFERuntimeError;
    
    private string funcName;
    private ubyte[] wasmBytes;
    private CTFERuntime runtime;
    
    this(string name, ubyte[] wasm) {
        this.funcName = name;
        this.wasmBytes = wasm;
        this.runtime = new CTFERuntime();
        this.runtime.loadModule(wasm);
    }
    
    override ExecutionResult call(long[] args) {
        try {
            int[] intArgs;
            foreach (arg; args) {
                intArgs ~= cast(int)arg;
            }
            
            auto result = runtime.callI32(funcName, intArgs);
            return ExecutionResult.fromInt(result.asInt());
            
        } catch (CTFERuntimeError e) {
            return ExecutionResult.failure(e.msg);
        }
    }
    
    override void dispose() {
        if (runtime) {
            destroy(runtime);
            runtime = null;
        }
    }
    
    override string name() { return funcName; }
}
