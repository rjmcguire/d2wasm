/**
 * Native Backend Implementation
 * 
 * Implements the Backend interface for native ARM64 target.
 * Uses copy-and-patch code generation for JIT compilation.
 */
module codegen.native.backend;

import codegen.backend : Backend, CompiledFunction, ExecutionResult;
import codegen.target : NativeSliceLayout;
import codegen.native.arm64_codegen : NativeCodeGen, CallFrameData, ErrorLocData,
    createCTFEHostFunctions;
import codegen.native.arm64.stencil_table;
import codegen.native.stencil_catalog;
import codegen.native.codegen_interface : Label, NativeDataSection, NativeCTFEContext,
    HostFunctionTable, CTFEErrorKind, ctfeErrorMessage, ctfeErrorMessageWithStack, setjmp;
import ast.nodes;
import ast.statements;
import ast.expressions;
import semantic.symbol_table;
import semantic.type_checker;

alias ArrayType = ast.nodes.ArrayType;

class NativeCompileError : Exception {
    SourceLocation location;
    this(string msg, SourceLocation loc) {
        super(msg);
        this.location = loc;
    }
}

class NativeBackend : Backend {
    private SymbolTable symbolTable;
    private string lastError;
    private SourceLocation lastErrorLoc;
    private bool enableStackTrace;
    
    this(SymbolTable st, bool enableStackTrace = true) {
        this.symbolTable = st;
        this.enableStackTrace = enableStackTrace;
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
            return new NativeCompiledFunction(func, symbolTable, enableStackTrace);
        } catch (NativeCompileError e) {
            lastError = "Native compile error: " ~ e.msg;
            lastErrorLoc = e.location;
            return null;
        } catch (Exception e) {
            lastError = "Native compile error: " ~ e.msg;
            lastErrorLoc = SourceLocation.init;
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
            return new NativeCompiledFunction(funcs, entryFuncName, symbolTable, enableStackTrace);
        } catch (NativeCompileError e) {
            lastError = "Native compile error: " ~ e.msg;
            lastErrorLoc = e.location;
            return null;
        } catch (Exception e) {
            lastError = "Native compile error: " ~ e.msg;
            lastErrorLoc = SourceLocation.init;
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
    override SourceLocation errorLocation() { return lastErrorLoc; }
    override string name() { return "native"; }
}

/**
 * Native compiled function - executes ARM64 code directly
 */
class NativeCompiledFunction : CompiledFunction {
    // Additional imports for this class
    import semantic.symbol_table : SymbolKind;
    
    private string funcName;
    private NativeCodeGen gen;  // renamed from codegen to avoid module name collision
    private size_t entryPoint;
    private size_t paramCount;           // number of function parameters
    private bool entryNeedsArena;        // whether the entry function has needsArena
    private SymbolTable symbolTable;     // for looking up struct types
    
    /// Discriminant for variable types — used with `final switch` for exhaustive dispatch.
    enum VarKind {
        scalar,
        struct_,
        slice,
        staticArray,
    }

    // Unified local variable info
    struct NativeLocalInfo {
        VarKind kind;
        size_t offset;            // Stack offset (size_t for 64-bit targets)
        StructDecl structDecl;    // Non-null when kind == struct_
        Type elementType;         // Element type for staticArray/slice
        uint staticArraySize;     // Element count when kind == staticArray
        uint staticArrayElemSize; // Element byte size when kind == staticArray
        uint sliceElemSize;       // Element byte size when kind == slice

        bool isStruct() const { return kind == VarKind.struct_; }
        bool isSlice() const { return kind == VarKind.slice; }
        bool isStaticArray() const { return kind == VarKind.staticArray; }

        /// Get element size for any array-like kind
        uint elemSize() const {
            if (kind == VarKind.staticArray) return staticArrayElemSize;
            if (kind == VarKind.slice) return sliceElemSize;
            return 4;
        }
    }
    private NativeLocalInfo[string] localVars;
    private size_t nextLocalOffset;
    private size_t totalLocalBytes;
    private size_t tempSlot;             // stack offset for expression temporaries
    private uint tempSlotDepth;          // nesting depth for temp slot usage (count, not bytes)

    // Large return tracking (hidden result pointer pattern)
    private bool currentFunctionHasHiddenResult;
    private size_t currentFunctionResultPtrOffset;
    private StructDecl currentFunctionReturnStructDecl;
    private size_t currentFunctionReturnArrayBytes;  // >0 for static array returns

    // Method tracking (hidden 'this' parameter)
    private StructDecl currentMethodStruct;  // non-null when compiling a method
    private size_t currentThisOffset;        // stack offset of 'this' pointer

    // Arena tracking (hidden __arena parameter)
    private bool currentFunctionHasArena;
    private size_t currentFunctionArenaOffset;

    // For return statements to jump to
    private Label epilogueLabel;

    // Loop stack for break/continue
    private struct NativeLoopContext {
        Label breakLabel;
        Label continueLabel;
    }
    private NativeLoopContext[] nativeLoopStack;
    
    // For multi-function support: map function names to their labels
    private Label[string] functionLabels;
    private FunctionDecl[string] functionDecls;  // for looking up parameter counts
    
    // Data section for external data (import() file contents, etc.) - Milestone 85/86
    private NativeDataSection dataSection;
    
    // Host function table for CTFE intrinsics - Milestone 87/88
    private HostFunctionTable hostFunctions;
    
    // Stack trace option
    private bool enableStackTrace;
    
    /// Single function constructor (original)
    this(FunctionDecl func, SymbolTable st, bool enableStackTrace = true) {
        import std.stdio : writeln;
        
        this.funcName = func.name;
        this.symbolTable = st;
        this.enableStackTrace = enableStackTrace;
        this.gen = NativeCodeGen.alloc(64 * 1024);  // 64KB code buffer
        this.dataSection = NativeDataSection.alloc(64 * 1024);  // 64KB data section
        this.hostFunctions = createCTFEHostFunctions();  // Milestone 88
        
        if (!gen.base) {
            throw new Exception("Failed to allocate executable memory");
        }
        if (!dataSection.base) {
            throw new Exception("Failed to allocate data section");
        }
        
        // Reserve space for inline call stack (must be before adding other data)
        if (enableStackTrace) {
            dataSection.reserveInlineStack();
        }
        
        // Store parameter count for call()
        this.paramCount = func.parameters.length;
        this.entryNeedsArena = func.needsArena && func.name != "main";

        // Compile the function
        compileFunction(func);
        
        // Finalize (resolve branches, make executable)
        if (!gen.finalize()) {
            throw new Exception("Failed to finalize native code");
        }
    }
    
    /// Multi-function constructor for CTFE with dependencies
    this(FunctionDecl[] funcs, string entryFuncName, SymbolTable st, bool enableStackTrace = true) {
        import std.stdio : writeln;
        
        this.funcName = entryFuncName;
        this.symbolTable = st;
        this.enableStackTrace = enableStackTrace;
        this.gen = NativeCodeGen.alloc(64 * 1024);  // 64KB code buffer
        this.dataSection = NativeDataSection.alloc(64 * 1024);  // 64KB data section
        this.hostFunctions = createCTFEHostFunctions();  // Milestone 88
        
        if (!gen.base) {
            throw new Exception("Failed to allocate executable memory");
        }
        if (!dataSection.base) {
            throw new Exception("Failed to allocate data section");
        }
        
        // Reserve space for inline call stack (must be before adding other data)
        if (enableStackTrace) {
            dataSection.reserveInlineStack();
        }
        
        // Store all function decls for call resolution
        // Methods use mangled names: StructName_methodName
        foreach (func; funcs) {
            string name = getMangledName(func);
            functionDecls[name] = func;
        }

        // Create labels for all functions before compiling any
        foreach (func; funcs) {
            string name = getMangledName(func);
            functionLabels[name] = gen.newLabel();
        }
        
        // Find entry function and store its param count
        if (auto entryFunc = entryFuncName in functionDecls) {
            this.paramCount = (*entryFunc).parameters.length;
            this.entryNeedsArena = (*entryFunc).needsArena && (*entryFunc).name != "main";
        } else {
            assert(0, "Entry function not found: " ~ entryFuncName);
        }
        
        // Compile all functions
        foreach (func; funcs) {
            compileFunction(func);
        }
        
        // Set entry point to the entry function
        if (auto entryLabel = entryFuncName in functionLabels) {
            entryPoint = (*entryLabel).offset;
        } else {
            assert(0, "Entry function label not found: " ~ entryFuncName);
        }
        
        // Finalize (resolve branches, make executable)
        if (!gen.finalize()) {
            throw new Exception("Failed to finalize native code");
        }

    }

    /// Get the mangled name for a function.
    /// Uses FunctionDecl.mangledName if set (by WASM emitter), otherwise computes it.
    private static string getMangledName(FunctionDecl func) {
        if (func.mangledName)
            return func.mangledName;
        // Fallback for native-only compilation (no WASM emitter ran)
        if (func.isMethod && func.parent !is null) {
            import codegen.mangle : computeMangledName;
            return computeMangledName([], func);
        }
        return func.name;
    }

    private void compileFunction(FunctionDecl func) {
        import std.stdio : writeln;

        // Skip forward declarations (no body)
        if (func.body_ is null)
            return;

        string name = getMangledName(func);

        // Bind function label (for multi-function mode)
        if (auto labelPtr = name in functionLabels) {
            gen.bindLabel(*labelPtr);
        }
        
        // For single-function mode, track entry point
        if (functionLabels.length == 0) {
            entryPoint = gen.pos;
        }
        
        // Reset local tracking for this function
        localVars.clear();
        nextLocalOffset = 0;
        
        // Check if function returns a struct (uses hidden result pointer)
        bool hasHiddenResultPtr = false;
        size_t resultPtrOffset = 0;
        StructDecl returnStructDecl = null;
        size_t returnArrayBytes = 0;
        if (auto userType = cast(UserType)func.returnType) {
            userType.ensureResolved(symbolTable);
            if (auto sd = userType.asStruct()) {
                hasHiddenResultPtr = true;
                returnStructDecl = sd;
                resultPtrOffset = nextLocalOffset;
                nextLocalOffset += 8;  // 64-bit pointer
            }
        } else if (auto arrayType = cast(ArrayType)func.returnType) {
            if (arrayType.arraySize !is null) {
                hasHiddenResultPtr = true;
                // Evaluate static array size
                if (auto sizeLit = cast(LiteralExpression)arrayType.arraySize) {
                    uint elemCount = cast(uint)sizeLit.value.get!long();
                    returnArrayBytes = elemCount * 4;  // assume int elements
                }
                resultPtrOffset = nextLocalOffset;
                nextLocalOffset += 8;  // 64-bit pointer
            } else {
                // Dynamic array (slice) return — same mechanism, different size
                hasHiddenResultPtr = true;
                returnArrayBytes = NativeSliceLayout.sizeof;  // 16
                resultPtrOffset = nextLocalOffset;
                nextLocalOffset += 8;  // 64-bit pointer
            }
        }
        currentFunctionHasHiddenResult = hasHiddenResultPtr;
        currentFunctionResultPtrOffset = resultPtrOffset;
        currentFunctionReturnStructDecl = returnStructDecl;
        currentFunctionReturnArrayBytes = returnArrayBytes;
        if (hasHiddenResultPtr) {
            assert(resultPtrOffset % 8 == 0,
                "Hidden result pointer offset must be 8-byte aligned for STR x0");
        }
        
        // For methods, register hidden 'this' parameter
        currentMethodStruct = null;
        if (func.isMethod && func.parent !is null) {
            if (auto sd = cast(StructDecl)func.parent) {
                currentMethodStruct = sd;
                // 'this' is a pointer (8 bytes) passed as a register arg
                currentThisOffset = nextLocalOffset;
                NativeLocalInfo thisInfo;
                thisInfo.offset = nextLocalOffset;
                thisInfo.kind = VarKind.struct_;
                thisInfo.structDecl = sd;
                localVars["this"] = thisInfo;
                nextLocalOffset += 8;  // 64-bit pointer
            }
        }

        // Register hidden arena parameter if function allocates
        currentFunctionHasArena = false;
        currentFunctionArenaOffset = 0;
        if (func.needsArena) {
            currentFunctionHasArena = true;
            currentFunctionArenaOffset = nextLocalOffset;
            nextLocalOffset += 8;
        }

        // Reserve space for parameters (x0/x1/x2... depending on hidden ptr)
        foreach (param; func.parameters) {
            NativeLocalInfo nli;
            nli.offset = nextLocalOffset;

            size_t paramSize = 4;  // default for scalar (int, bool, etc.)
            if (auto userType = cast(UserType)param.type) {
                userType.ensureResolved(symbolTable);
                if (auto structDecl = userType.asStruct()) {
                    assert(structDecl.structSize > 0,
                        "StructDecl '" ~ structDecl.name ~ "' has zero size - layout not computed");
                    nli.kind = VarKind.struct_;
                    nli.structDecl = structDecl;
                    paramSize = structDecl.structSize;
                }
            } else if (auto arrayType = cast(ArrayType)param.type) {
                if (arrayType.arraySize !is null) {
                    // Static array param — register holds pointer to caller's data
                    nli.kind = VarKind.staticArray;
                    // Evaluate array size
                    auto sizeLit = cast(LiteralExpression)arrayType.arraySize;
                    assert(sizeLit !is null, "Static array param size is not a LiteralExpression");
                    uint elemCount = cast(uint)sizeLit.value.get!long();
                    nli.staticArraySize = elemCount;
                    nli.staticArrayElemSize = 4;  // assume int elements for now
                    paramSize = elemCount * 4;
                } else {
                    // Dynamic array (slice) param
                    nli.kind = VarKind.slice;
                    nli.sliceElemSize = cast(uint)arrayType.elementType.size();
                    if (nli.sliceElemSize == 0) nli.sliceElemSize = 4;
                    paramSize = NativeSliceLayout.sizeof;
                }
            }
            localVars[param.name] = nli;
            nextLocalOffset += paramSize;
        }
        
        // Count bytes needed for locals in the body
        size_t bodyLocalBytes = countLocalBytesInStatement(func.body_);

        // Reserve extra space for expression temporaries
        // Need 40 bytes for slice append temps: element(4) + newCap(4) + newPtr(8) + loopIdx(4) + loopVal(4) + padding
        // Plus space for struct construction temps (at tempSlot + 16 onwards)
        size_t tempSlotOffset = nextLocalOffset + bodyLocalBytes;
        tempSlot = (tempSlotOffset + 7) & ~7;  // 8-byte align for pointer-safe scratch
        size_t totalNeeded = tempSlotOffset + 64;  // 64 bytes for temps (struct construction + slice append)
        totalLocalBytes = (totalNeeded + 15) & ~15;  // 16-byte aligned
        
        // Create epilogue label for return statements
        epilogueLabel = gen.newLabel();
        
        // Emit prologue
        if (totalLocalBytes > 0) {
            gen.emitPrologueWithLocals(totalLocalBytes);
        } else {
            gen.emitPrologue();
        }
        
        // If function has hidden result pointer, spill it first (from x0)
        if (currentFunctionHasHiddenResult) {
            gen.emitStorePtr(currentFunctionResultPtrOffset);  // Save x0 (64-bit ptr)
        }
        
        // Spill 'this' pointer from register to stack
        if (currentMethodStruct !is null) {
            int thisReg = currentFunctionHasHiddenResult ? 1 : 0;
            // Move this register to x0 for storing (if not already there)
            switch (thisReg) {
                case 0: break;  // already in x0
                case 1: gen.emitMoveX1ToX0(); break;
                default: assert(0, "this register > 1 not supported");
            }
            gen.emitStorePtr(currentThisOffset);  // Save 64-bit pointer
        }

        // Spill hidden arena pointer from register to stack
        if (currentFunctionHasArena) {
            int arenaReg = (currentFunctionHasHiddenResult ? 1 : 0)
                         + (currentMethodStruct !is null ? 1 : 0);
            switch (arenaReg) {
                case 0: break;  // already in x0
                case 1: gen.emitMoveX1ToX0(); break;
                case 2: gen.emitMoveX2ToX0(); break;
                default: assert(0, "arena register > 2 not supported");
            }
            gen.emitStorePtr(currentFunctionArenaOffset);
        }

        // Spill parameters from registers to stack
        // ARM64 calling convention: first 8 args in x0-x7
        // Hidden params shift user params: result_ptr, this, arena, then user params
        int regOffset = (currentFunctionHasHiddenResult ? 1 : 0)
                      + (currentMethodStruct !is null ? 1 : 0)
                      + (currentFunctionHasArena ? 1 : 0);
        foreach (i, param; func.parameters) {
            int regIdx = cast(int)i + regOffset;
            if (regIdx >= 4) {
                throw new Exception("Native backend: more than 4 parameters not yet supported");
            }
            // Store parameter register to its stack slot
            auto nli = param.name in localVars;
            assert(nli !is null, "Parameter '" ~ param.name ~ "' not in localVars");
            size_t offset = nli.offset;

            final switch (nli.kind) {
                case VarKind.struct_:
                    // Register contains pointer to struct - copy struct data to our stack
                    switch (regIdx) {
                        case 0: gen.emitMoveX0ToX9(); break;
                        case 1: gen.emitMoveX1ToX9(); break;
                        case 2: gen.emitMoveX2ToX9(); break;
                        case 3: gen.emitMoveX3ToX9(); break;
                        default: break;
                    }
                    size_t structSize = nli.structDecl.structSize;
                    for (uint fieldOff = 0; fieldOff < structSize; fieldOff += 4) {
                        gen.emitLoadFromX9Offset(fieldOff);
                        gen.emitStoreLocal32(offset + fieldOff);
                    }
                    break;

                case VarKind.staticArray:
                    // Register contains pointer to caller's array - copy data to our stack
                    switch (regIdx) {
                        case 0: gen.emitMoveX0ToX9(); break;
                        case 1: gen.emitMoveX1ToX9(); break;
                        case 2: gen.emitMoveX2ToX9(); break;
                        case 3: gen.emitMoveX3ToX9(); break;
                        default: break;
                    }
                    uint arrBytes = nli.staticArraySize * nli.staticArrayElemSize;
                    for (uint off = 0; off < arrBytes; off += 4) {
                        gen.emitLoadFromX9Offset(off);
                        gen.emitStoreLocal32(offset + off);
                    }
                    break;

                case VarKind.slice:
                    // Register contains pointer to caller's slice struct - copy to our stack
                    switch (regIdx) {
                        case 0: gen.emitMoveX0ToX9(); break;
                        case 1: gen.emitMoveX1ToX9(); break;
                        case 2: gen.emitMoveX2ToX9(); break;
                        case 3: gen.emitMoveX3ToX9(); break;
                        default: break;
                    }
                    for (size_t off = 0; off < NativeSliceLayout.sizeof; off += 4) {
                        gen.emitLoadFromX9Offset(off);
                        gen.emitStoreLocal32(offset + off);
                    }
                    break;

                case VarKind.scalar:
                    // Simple scalar - store the register value
                    switch (regIdx) {
                        case 0: gen.emitStoreLocal32(offset); break;        // x0
                        case 1: gen.emitStoreLocal32FromX1(offset); break;  // x1
                        case 2: gen.emitStoreLocal32FromX2(offset); break;  // x2
                        case 3: gen.emitStoreLocal32FromX3(offset); break;  // x3
                        default: break;
                    }
                    break;
            }
        }
        
        // Emit inline call stack push (for error reporting)
        // Uses inline code to write directly to data section - no FFI overhead
        string fileName = func.location.filename ? func.location.filename : "";
        emitInlinePushCall(func.name, fileName, func.location.line);
        
        // Compile body
        if (func.body_) {
            compileStatement(func.body_);
        }
        
        // Bind epilogue label - return statements jump here
        gen.bindLabel(epilogueLabel);
        
        // Emit inline call stack pop (before return)
        emitInlinePopCall();
        
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
    /**
     * Count stack bytes needed for expression temporaries.
     * Expressions like ArrayLiteralExpression, SliceExpression, and string literals
     * allocate temp space on the stack during code generation. This function walks
     * the expression tree to account for all such allocations so the frame size
     * is computed correctly before code generation begins.
     */
    private size_t countExpressionBytes(Expression expr) {
        if (expr is null) return 0;

        size_t bytes = 0;

        if (auto arrLit = cast(ArrayLiteralExpression)expr) {
            uint elemCount = cast(uint)arrLit.elements.length;
            uint dataSize = elemCount * 4;
            // 8-byte alignment padding + slice struct
            bytes += ((dataSize + 7) & ~7) + NativeSliceLayout.sizeof;
            foreach (elem; arrLit.elements)
                bytes += countExpressionBytes(elem);
        } else if (auto sliceExpr = cast(SliceExpression)expr) {
            // Temp slice struct with 8-byte alignment
            bytes += 8 + NativeSliceLayout.sizeof;
            bytes += countExpressionBytes(sliceExpr.array);
            bytes += countExpressionBytes(sliceExpr.start);
            bytes += countExpressionBytes(sliceExpr.end);
        } else if (auto lit = cast(LiteralExpression)expr) {
            if (lit.value.type == typeid(string))
                bytes += 8 + NativeSliceLayout.sizeof;
        } else if (auto binOp = cast(BinaryExpression)expr) {
            bytes += countExpressionBytes(binOp.left);
            bytes += countExpressionBytes(binOp.right);
            bytes += countExpressionBytes(binOp.loweredCall);
        } else if (auto call = cast(CallExpression)expr) {
            bytes += countExpressionBytes(call.function_);
            foreach (arg; call.arguments)
                bytes += countExpressionBytes(arg);
        } else if (auto unary = cast(UnaryExpression)expr) {
            bytes += countExpressionBytes(unary.operand);
        } else if (auto member = cast(MemberExpression)expr) {
            bytes += countExpressionBytes(member.object);
        } else if (auto index = cast(IndexExpression)expr) {
            bytes += countExpressionBytes(index.array);
            bytes += countExpressionBytes(index.index);
        } else if (auto castExpr = cast(CastExpression)expr) {
            bytes += countExpressionBytes(castExpr.expression);
        } else if (auto assign = cast(AssignmentExpression)expr) {
            bytes += countExpressionBytes(assign.left);
            bytes += countExpressionBytes(assign.right);
            bytes += countExpressionBytes(assign.loweredCall);
        }
        // IdentifierExpression, TraitsExpression, IsExpression, TemplateInstantiationExpression,
        // ImportExpression — no stack temp allocation

        return bytes;
    }

    private size_t countLocalBytesInStatement(Statement stmt) {
        if (stmt is null) return 0;

        size_t bytes = 0;

        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                bytes += countLocalBytesInStatement(s);
            }
        } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
            // Check type to determine size
            if (auto userType = cast(UserType)varDecl.type) {
                userType.ensureResolved(symbolTable);
                if (auto sd = userType.asStruct()) {
                    // Zero-size structs (methods-only, no data fields) are valid
                    bytes = sd.structSize > 0 ? cast(uint)sd.structSize : 0;
                } else {
                    bytes = 4;
                }
            } else if (auto arrType = cast(ArrayType)varDecl.type) {
                if (arrType.arraySize is null) {
                    // Slice struct + data
                    bytes = NativeSliceLayout.sizeof;
                    // Add data size if initialized with literal
                    if (auto arrLit = cast(ArrayLiteralExpression)varDecl.initializer) {
                        size_t elemSz = arrType.elementType.size();
                        assert(elemSz > 0, "Slice element type has zero size");
                        bytes += arrLit.elements.length * elemSz;
                    }
                } else {
                    // Static array: inline storage for N elements
                    auto sizeLit = cast(LiteralExpression)arrType.arraySize;
                    assert(sizeLit !is null, "Static array size is not a LiteralExpression");
                    assert(sizeLit.value.type == typeid(long), "Static array size literal is not a long");
                    uint length = cast(uint)sizeLit.value.get!long();
                    size_t elemSz = arrType.elementType.size();
                    assert(elemSz > 0, "Static array element type has zero size");
                    bytes = length * elemSz;
                }
            } else {
                bytes = 4;  // int, bool, etc.
            }
            // Add expression temps from initializer
            bytes += countExpressionBytes(varDecl.initializer);
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            bytes += countExpressionBytes(ifStmt.condition);
            bytes += countLocalBytesInStatement(ifStmt.thenStatement);
            bytes += countLocalBytesInStatement(ifStmt.elseStatement);
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            bytes += countExpressionBytes(whileStmt.condition);
            bytes += countLocalBytesInStatement(whileStmt.body_);
        } else if (auto forStmt = cast(ForStatement)stmt) {
            bytes += countLocalBytesInStatement(forStmt.init);
            bytes += countExpressionBytes(forStmt.condition);
            bytes += countExpressionBytes(forStmt.update);
            bytes += countLocalBytesInStatement(forStmt.body_);
        } else if (auto retStmt = cast(ReturnStatement)stmt) {
            bytes += countExpressionBytes(retStmt.value);
        } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
            bytes += countExpressionBytes(exprStmt.expression);
        } else if (cast(BreakStatement)stmt || cast(ContinueStatement)stmt
                   || cast(MixinStatement)stmt || cast(StructDeclarationStatement)stmt) {
            // No local allocations
        } else {
            assert(0, "countLocalBytesInStatement: unhandled statement type: " ~ typeid(stmt).name);
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
                if (currentFunctionHasHiddenResult) {
                    // Unified large return: copy N bytes from source to result pointer
                    // Works for structs, static arrays, and slices — all use the same mechanism
                    size_t returnSize = 0;
                    if (currentFunctionReturnStructDecl !is null)
                        returnSize = currentFunctionReturnStructDecl.structSize;
                    else if (currentFunctionReturnArrayBytes > 0)
                        returnSize = currentFunctionReturnArrayBytes;

                    if (returnSize > 0) {
                        compileExpression(ret.value);  // x0 = source address

                        // Allocate srcTempSlot AFTER compileExpression —
                        // expression temps (e.g., standalone SliceExpression)
                        // may have advanced nextLocalOffset past tempSlot.
                        size_t srcTempSlot = (nextLocalOffset + 7) & ~7;
                        assert(srcTempSlot + 8 <= totalLocalBytes,
                            "srcTempSlot overflows frame");
                        gen.emitStorePtr(srcTempSlot);  // Save 64-bit ptr

                        for (size_t off = 0; off < returnSize; off += 4) {
                            gen.emitLoadPtr(srcTempSlot);      // x0 = src ptr
                            gen.emitLoadFromPointer(off);        // x0 = *(src + off)
                            gen.emitMoveX0ToX9();                // x9 = value

                            gen.emitLoadPtr(currentFunctionResultPtrOffset);  // x0 = dest ptr
                            gen.emitStoreToPointerFromX9(off);   // *(dest + off) = x9
                        }
                    }
                } else {
                    compileExpression(ret.value);
                }
            }
            // Jump to epilogue (which will restore stack and return)
            gen.emitBranch(epilogueLabel);
        } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
            compileExpression(exprStmt.expression);
        } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
            // Check if this is a struct type or slice type
            StructDecl structType = null;
            bool isSlice = false;
            uint staticArrayLength = 0;
            size_t varSize = 4;  // default to 4 bytes for int
            
            if (auto userType = cast(UserType)varDecl.type) {
                userType.ensureResolved(symbolTable);
                if (auto sd = userType.asStruct()) {
                    // Zero-size structs (methods-only, no data fields) are valid
                    structType = sd;
                    varSize = sd.structSize > 0 ? sd.structSize : 0;
                }
            } else if (auto arrType = cast(ArrayType)varDecl.type) {
                if (arrType.arraySize is null) {
                    // Dynamic array (slice) = NativeSliceLayout.sizeof bytes on native (64-bit ptr)
                    isSlice = true;
                    varSize = NativeSliceLayout.sizeof;
                    // Add data size if initialized with literal
                    if (auto arrLit = cast(ArrayLiteralExpression)varDecl.initializer) {
                        varSize += arrLit.elements.length * 4;
                    }
                } else {
                    // Static array: inline storage for N elements
                    auto sizeLit = cast(LiteralExpression)arrType.arraySize;
                    assert(sizeLit !is null, "Static array size is not a LiteralExpression");
                    assert(sizeLit.value.type == typeid(long), "Static array size literal is not a long");
                    uint length = cast(uint)sizeLit.value.get!long();
                    size_t elemSz = arrType.elementType.size();
                    if (elemSz == 0) elemSz = 4;
                    varSize = length * elemSz;
                    staticArrayLength = length;
                }
            }
            
            // Allocate stack slot for this variable
            // Slices contain a 64-bit pointer and need 8-byte alignment
            // for STR x0, [sp, #imm] encoding (imm must be multiple of 8)
            if (isSlice) {
                nextLocalOffset = (nextLocalOffset + 7) & ~7;
            }
            NativeLocalInfo nli;
            nli.offset = nextLocalOffset;
            if (structType) {
                nli.kind = VarKind.struct_;
                nli.structDecl = structType;
            } else if (isSlice) {
                nli.kind = VarKind.slice;
                if (auto at = cast(ArrayType)varDecl.type) {
                    nli.elementType = at.elementType;
                    nli.sliceElemSize = cast(uint)at.elementType.size();
                    if (nli.sliceElemSize == 0) nli.sliceElemSize = 4;
                } else {
                    nli.sliceElemSize = 4;
                }
            } else if (staticArrayLength > 0) {
                nli.kind = VarKind.staticArray;
                nli.staticArraySize = staticArrayLength;
                if (auto at = cast(ArrayType)varDecl.type) {
                    nli.elementType = at.elementType;
                    nli.staticArrayElemSize = cast(uint)at.elementType.size();
                    if (nli.staticArrayElemSize == 0) nli.staticArrayElemSize = 4;
                } else {
                    nli.staticArrayElemSize = 4;
                }
            }
            // else: kind stays VarKind.scalar (default)
            localVars[varDecl.name] = nli;

            // Zero-initialize variables without explicit initializer
            // (D guarantees .init = 0 for int types, null for slices)
            if (!varDecl.initializer && varSize > 0) {
                if (nli.isStaticArray || nli.isStruct || nli.isSlice) {
                    gen.emitImm32(stencil_load_imm32, 0);
                    for (size_t off = 0; off < varSize; off += 4) {
                        gen.emitStoreLocal32(nli.offset + off);
                    }
                } else if (nli.kind == VarKind.scalar) {
                    gen.emitImm32(stencil_load_imm32, 0);
                    gen.emitStoreLocal32(nli.offset);
                }
            }

            // Compile initializer if present
            if (varDecl.initializer) {
                if (nli.isStruct) {
                    // Struct template construction: Pair!(int, int)(10, 20)
                    if (auto tmplInst = cast(TemplateInstantiationExpression)varDecl.initializer) {
                        if (tmplInst.resolvedStructInstantiation) {
                            auto sd = tmplInst.resolvedStructInstantiation;
                            for (size_t i = 0; i < sd.fields.length && i < tmplInst.callArguments.length; i++) {
                                auto field = sd.fields[i];
                                size_t fieldOffset = nextLocalOffset + field.offset;
                                compileExpression(tmplInst.callArguments[i]);
                                gen.emitStoreLocal32(fieldOffset);
                            }
                        }
                    } else if (auto call = cast(CallExpression)varDecl.initializer) {
                        if (auto funcIdent = cast(IdentifierExpression)call.function_) {
                            auto symbol = symbolTable.lookupSymbol(funcIdent.name);
                            assert(symbol !is null,
                                "Struct var '" ~ varDecl.name ~ "' initializer calls '" ~
                                funcIdent.name ~ "' which is not in symbol table");
                            assert(symbol.kind == SymbolKind.Type || symbol.kind == SymbolKind.Function,
                                "Struct var '" ~ varDecl.name ~ "' initializer calls '" ~
                                funcIdent.name ~ "' which is neither Type nor Function");
                            if (symbol && symbol.kind == SymbolKind.Type) {
                                if (auto sd = symbol.type.asStruct()) {
                                        // Initialize struct fields directly at our variable's location
                                        for (size_t i = 0; i < sd.fields.length && i < call.arguments.length; i++) {
                                            auto field = sd.fields[i];
                                            size_t fieldOffset = nextLocalOffset + field.offset;
                                            uint valueSize = cast(uint)field.type.size();
                                            
                                            // Aggregate types (struct, class, static array) are passed
                                            // by address — need to copy their data, not store address
                                            if (field.type.isAggregate() && valueSize > 0) {
                                                compileExpression(call.arguments[i]);  // x0 = address of source
                                                // Copy word by word
                                                for (uint off = 0; off < valueSize; off += 4) {
                                                    gen.emitLoadFromPointer(off);
                                                    gen.emitStoreLocal32(fieldOffset + off);
                                                    if (off + 4 < valueSize) {
                                                        compileExpression(call.arguments[i]);  // reload src addr
                                                    }
                                                }
                                                continue;
                                            }
                                            
                                            compileExpression(call.arguments[i]);
                                            gen.emitStoreLocal32(fieldOffset);
                                        }
                                }
                            } else if (symbol && symbol.kind == SymbolKind.Function) {
                                // Function call returning struct — hidden result pointer pattern
                                // ARM64: x0 = result ptr, [x1 = arena], x1/x2..xN = actual args
                                assert((funcIdent.name in functionLabels) !is null,
                                    "Struct return call to '" ~ funcIdent.name ~
                                    "' but no function label exists");

                                // Check if callee needs arena
                                bool calleeNeedsArena = false;
                                if (auto calleeDecl = funcIdent.name in functionDecls) {
                                    calleeNeedsArena = (*calleeDecl).needsArena;
                                }
                                int arenaShift = calleeNeedsArena ? 1 : 0;

                                // First, compile and save all arguments to temp slots
                                size_t tempOffset = nextLocalOffset + varSize;
                                size_t[] argTemps;
                                foreach (arg; call.arguments) {
                                    compileExpression(arg);
                                    gen.emitStoreLocal32(tempOffset);
                                    argTemps ~= tempOffset;
                                    tempOffset += 4;
                                }

                                // Load args into registers in reverse order
                                // User args go into x(1+arenaShift), x(2+arenaShift), ...
                                for (long i = cast(long)argTemps.length - 1; i >= 0; i--) {
                                    gen.emitLoadLocal32(argTemps[cast(size_t)i]);
                                    switch (cast(int)i + 1 + arenaShift) {
                                        case 1: gen.emitMoveX0ToX1(); break;
                                        case 2: gen.emitMoveX0ToX2(); break;
                                        case 3: gen.emitMoveX0ToX3(); break;
                                        default: assert(0, "argument register > 3");
                                    }
                                }

                                // Load arena into x1 if callee needs it
                                if (calleeNeedsArena) {
                                    gen.emitLoadPtr(currentFunctionArenaOffset);
                                    gen.emitMoveX0ToX1();
                                }

                                // Load result address into x0 (first arg)
                                gen.emitStackAddress(nextLocalOffset);

                                // Call the function
                                auto funcLabelPtr = funcIdent.name in functionLabels;
                                if (funcLabelPtr is null) {
                                    throw new Exception("Function not compiled: " ~ funcIdent.name);
                                }
                                gen.emitCall(*funcLabelPtr);
                                // Result is now written to nextLocalOffset
                            }
                        }
                    }
                } else if (nli.isSlice) {
                    // Slice initialization from array literal, string literal, or import()
                    if (auto arrLit = cast(ArrayLiteralExpression)varDecl.initializer) {
                        compileSliceInit(nextLocalOffset, arrLit);
                    } else if (auto importExpr = cast(ImportExpression)varDecl.initializer) {
                        // Milestone 86: import() in native backend
                        compileImportInit(nextLocalOffset, importExpr);
                    } else if (auto litExpr = cast(LiteralExpression)varDecl.initializer) {
                        if (litExpr.value.type == typeid(string)) {
                            compileStringLiteralInit(nextLocalOffset, litExpr.value.get!string());
                        } else {
                            throw new Exception("Unsupported literal type for slice init");
                        }
                    } else if (auto sliceExpr = cast(SliceExpression)varDecl.initializer) {
                        // Slice init from another array: int[] s = arr[1..4]
                        auto sourceIdent = cast(IdentifierExpression)sliceExpr.array;
                        if (!sourceIdent)
                            throw new Exception("Complex slice source not supported in native slice init");
                        auto srcInfo = sourceIdent.name in localVars;
                        if (srcInfo is null || (!srcInfo.isSlice && !srcInfo.isStaticArray))
                            throw new Exception("Can only slice array-like variables in native slice init");
                        uint srcElemSize = srcInfo.elemSize;

                        // Compute ptr = base + start * elemSize → store at nli.offset
                        if (srcInfo.isSlice) {
                            gen.emitLoadPtr(srcInfo.offset);  // 64-bit ptr
                        } else {
                            gen.emitStackAddress(srcInfo.offset);  // static array address
                        }
                        gen.emitMoveX0ToX9();  // x9 = base ptr
                        compileExpression(sliceExpr.start);
                        gen.emitMoveX0ToX1();
                        gen.emitImm32(stencil_load_imm32, srcElemSize);
                        gen.emit(stencil_mul_i32);  // x0 = start * elemSize
                        gen.emitMoveX0ToX1();
                        gen.emitMoveX9ToX0();
                        gen.emit(stencil_add_i64);  // x0 = base + start * elemSize (64-bit ptr)
                        gen.emitStorePtr(nli.offset);  // store 64-bit ptr

                        // Compute length = end - start → store at nli.offset + LENGTH_OFFSET
                        compileExpression(sliceExpr.end);
                        gen.emitMoveX0ToX9();
                        compileExpression(sliceExpr.start);
                        gen.emitMoveX0ToX1();
                        gen.emitMoveX9ToX0();
                        gen.emit(stencil_sub_i32);  // x0 = end - start
                        gen.emitStoreLocal32(nli.offset + NativeSliceLayout.LENGTH_OFFSET);

                        // Capacity = length
                        compileExpression(sliceExpr.end);
                        gen.emitMoveX0ToX9();
                        compileExpression(sliceExpr.start);
                        gen.emitMoveX0ToX1();
                        gen.emitMoveX9ToX0();
                        gen.emit(stencil_sub_i32);
                        gen.emitStoreLocal32(nli.offset + NativeSliceLayout.CAPACITY_OFFSET);
                    } else if (auto callExpr = cast(CallExpression)varDecl.initializer) {
                        // Function call returning slice — hidden result pointer pattern
                        if (auto funcIdent = cast(IdentifierExpression)callExpr.function_) {
                            auto funcLabelPtr = funcIdent.name in functionLabels;
                            if (funcLabelPtr is null)
                                throw new Exception("Function not compiled: " ~ funcIdent.name);

                            bool calleeNeedsArena = false;
                            if (auto calleeDecl = funcIdent.name in functionDecls)
                                calleeNeedsArena = (*calleeDecl).needsArena;
                            int arenaShift = calleeNeedsArena ? 1 : 0;

                            // Compile and save all arguments to temp slots (64-bit for pointer args)
                            size_t tempOffset = (nextLocalOffset + varSize + 7) & ~7;  // 8-byte align
                            size_t[] argTemps;
                            foreach (arg; callExpr.arguments) {
                                compileExpression(arg);
                                gen.emitStorePtr(tempOffset);  // 64-bit store — pointers need full width
                                argTemps ~= tempOffset;
                                tempOffset += 8;
                            }

                            // Load args into registers (user args after result ptr + arena)
                            for (long i = cast(long)argTemps.length - 1; i >= 0; i--) {
                                gen.emitLoadPtr(argTemps[cast(size_t)i]);  // 64-bit load
                                switch (cast(int)i + 1 + arenaShift) {
                                    case 1: gen.emitMoveX0ToX1(); break;
                                    case 2: gen.emitMoveX0ToX2(); break;
                                    case 3: gen.emitMoveX0ToX3(); break;
                                    default: assert(0, "argument register > 3");
                                }
                            }

                            // Load arena into x1 if callee needs it
                            if (calleeNeedsArena) {
                                gen.emitLoadPtr(currentFunctionArenaOffset);
                                gen.emitMoveX0ToX1();
                            }

                            // x0 = result ptr (stack address of this slice variable)
                            gen.emitStackAddress(nli.offset);

                            gen.emitCall(*funcLabelPtr);
                        } else {
                            throw new Exception("Complex call target not supported for slice init");
                        }
                    } else {
                        throw new Exception("Slice can only be initialized from array literal, string literal, slice, call, or import()");
                    }
                } else if (nli.isStaticArray) {
                    // Static array initialization from array literal
                    if (auto arrLit = cast(ArrayLiteralExpression)varDecl.initializer) {
                        // Store each element directly on stack
                        foreach (i, elem; arrLit.elements) {
                            compileExpression(elem);
                            gen.emitStoreLocal32(nextLocalOffset + i * 4);
                        }
                    } else if (auto call = cast(CallExpression)varDecl.initializer) {
                        // Function call returning static array — hidden result pointer
                        if (auto funcIdent = cast(IdentifierExpression)call.function_) {
                            auto funcLabelPtr = funcIdent.name in functionLabels;
                            if (funcLabelPtr is null)
                                throw new Exception("Function not compiled: " ~ funcIdent.name);

                            // Check if callee needs arena
                            bool calleeNeedsArena = false;
                            if (auto calleeDecl = funcIdent.name in functionDecls) {
                                calleeNeedsArena = (*calleeDecl).needsArena;
                            }
                            int arenaShift = calleeNeedsArena ? 1 : 0;

                            // Compile and save all arguments to temp slots
                            size_t tempOffset = nextLocalOffset + varSize;
                            size_t[] argTemps;
                            foreach (arg; call.arguments) {
                                compileExpression(arg);
                                gen.emitStoreLocal32(tempOffset);
                                argTemps ~= tempOffset;
                                tempOffset += 4;
                            }

                            // Load args into registers in reverse order
                            // User args go into x(1+arenaShift), x(2+arenaShift), ...
                            for (long i = cast(long)argTemps.length - 1; i >= 0; i--) {
                                gen.emitLoadLocal32(argTemps[cast(size_t)i]);
                                switch (cast(int)i + 1 + arenaShift) {
                                    case 1: gen.emitMoveX0ToX1(); break;
                                    case 2: gen.emitMoveX0ToX2(); break;
                                    case 3: gen.emitMoveX0ToX3(); break;
                                    default: assert(0, "argument register > 3");
                                }
                            }

                            // Load arena into x1 if callee needs it
                            if (calleeNeedsArena) {
                                gen.emitLoadPtr(currentFunctionArenaOffset);
                                gen.emitMoveX0ToX1();
                            }

                            // x0 = result address (stack address of static array)
                            gen.emitStackAddress(nextLocalOffset);
                            gen.emitCall(*funcLabelPtr);
                        } else {
                            throw new Exception("Static array init from non-identifier call not supported");
                        }
                    } else {
                        throw new Exception("Static array can only be initialized from array literal or function call");
                    }
                } else {
                    compileExpression(varDecl.initializer);
                    gen.emitStoreLocal32(nextLocalOffset);
                }
            }
            
            nextLocalOffset += varSize;
            assert(nextLocalOffset <= tempSlot,
                "Frame overflow in var decl: nextLocalOffset exceeds tempSlot");
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

            nativeLoopStack ~= NativeLoopContext(loopEnd, loopStart);

            // Loop start (continue target)
            gen.bindLabel(loopStart);

            // Compile condition (result in x0)
            compileExpression(whileStmt.condition);

            // Exit loop if condition is zero
            gen.emitBranchIfZero(loopEnd);

            // Compile body
            compileStatement(whileStmt.body_);

            // Jump back to start
            gen.emitBranch(loopStart);

            // Loop end (break target)
            gen.bindLabel(loopEnd);

            nativeLoopStack = nativeLoopStack[0 .. $ - 1];
        } else if (auto forStmt = cast(ForStatement)stmt) {
            // Compile: for (init; cond; update) { body }
            auto loopStart = gen.newLabel();
            auto loopEnd = gen.newLabel();
            auto updateLabel = gen.newLabel();

            // Compile init (if present)
            if (forStmt.init) {
                compileStatement(forStmt.init);
            }

            nativeLoopStack ~= NativeLoopContext(loopEnd, updateLabel);

            // Loop start
            gen.bindLabel(loopStart);

            // Compile condition (if present, result in x0)
            if (forStmt.condition) {
                compileExpression(forStmt.condition);
                // Exit loop if condition is zero
                gen.emitBranchIfZero(loopEnd);
            }

            // Compile body
            compileStatement(forStmt.body_);

            // Update (continue target)
            gen.bindLabel(updateLabel);
            if (forStmt.update) {
                compileExpression(forStmt.update);
            }

            // Jump back to start
            gen.emitBranch(loopStart);

            // Loop end (break target)
            gen.bindLabel(loopEnd);

            nativeLoopStack = nativeLoopStack[0 .. $ - 1];
        } else if (cast(BreakStatement)stmt) {
            if (nativeLoopStack.length == 0)
                throw new Exception("break statement outside of loop");
            gen.emitBranch(nativeLoopStack[$ - 1].breakLabel);
        } else if (cast(ContinueStatement)stmt) {
            if (nativeLoopStack.length == 0)
                throw new Exception("continue statement outside of loop");
            gen.emitBranch(nativeLoopStack[$ - 1].continueLabel);
        } else if (cast(StructDeclarationStatement)stmt) {
            // Inner struct declaration — no runtime code
        } else if (auto mixinStmt = cast(MixinStatement)stmt) {
            if (mixinStmt.isExpanded) {
                foreach (s; mixinStmt.expandedStatements) {
                    compileStatement(s);
                }
            }
        } else {
            assert(0, "compileStatement: unhandled statement type: " ~ typeid(stmt).name);
        }
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
            } else if (lit.value.type == typeid(char)) {
                gen.emitImm32(stencil_load_imm32, cast(int)lit.value.get!char);
            } else if (lit.value.type == typeid(string)) {
                // String literal in expression context (e.g., as a call argument)
                // Allocate a temp slice on the local stack, populate it, return pointer
                string strVal = lit.value.get!string();
                size_t tempOffset = (nextLocalOffset + 7) & ~7;  // 8-byte align
                nextLocalOffset = tempOffset + NativeSliceLayout.sizeof;
                assert(nextLocalOffset <= tempSlot,
                    "Frame overflow in string literal: nextLocalOffset exceeds tempSlot");
                compileStringLiteralInit(tempOffset, strVal);
                gen.emitStackAddress(tempOffset);
            } else {
                throw new Exception("Literal type not supported: " ~ lit.value.type.toString());
            }
        } else if (auto binOp = cast(BinaryExpression)expr) {
            // Lowered shift operators — emit the call instead of raw opcode
            if (binOp.loweredCall) {
                compileExpression(binOp.loweredCall);
                return;
            }

            // Short-circuit evaluation for && and ||
            if (binOp.operator == BinaryExpression.Operator.LogicalAnd) {
                // a && b: evaluate a; if 0, result=0; else evaluate b, normalize to 0/1
                compileExpression(binOp.left);
                auto skipRight = gen.newLabel();
                auto done = gen.newLabel();
                gen.emitBranchIfZero(skipRight);
                compileExpression(binOp.right);
                gen.emitMoveX0ToX1();
                gen.emitImm32(stencil_load_imm32, 0);
                gen.emit(stencil_ne_i32);
                gen.emitBranch(done);
                gen.bindLabel(skipRight);
                gen.emitImm32(stencil_load_imm32, 0);
                gen.bindLabel(done);
                return;
            }
            if (binOp.operator == BinaryExpression.Operator.LogicalOr) {
                // a || b: evaluate a; if non-zero, result=1; else evaluate b, normalize to 0/1
                compileExpression(binOp.left);
                auto evalRight = gen.newLabel();
                auto done = gen.newLabel();
                gen.emitBranchIfZero(evalRight);
                gen.emitImm32(stencil_load_imm32, 1);
                gen.emitBranch(done);
                gen.bindLabel(evalRight);
                compileExpression(binOp.right);
                gen.emitMoveX0ToX1();
                gen.emitImm32(stencil_load_imm32, 0);
                gen.emit(stencil_ne_i32);
                gen.bindLabel(done);
                return;
            }

            // Check if left operand might clobber x1 (function call, nested binary expr, or index expr)
            // IndexExpression uses x1 internally for address calculation
            bool leftMightClobber = containsFunctionCall(binOp.left) ||
                                    cast(BinaryExpression)binOp.left !is null ||
                                    cast(IndexExpression)binOp.left !is null;

            // Compile right operand first (into x0)
            compileExpression(binOp.right);
            
            if (leftMightClobber) {
                // Save right result to temp slot (function calls clobber x0-x7)
                // Use depth-aware temp slot; +16 reserves first 16 bytes for inline push/pop saves
                size_t myTempSlot = tempSlot + 16 + (tempSlotDepth * 4);
                tempSlotDepth++;
                gen.emitStoreLocal32(myTempSlot);  // store w0 to temp slot (32-bit)
                // Compile left operand (into x0)
                compileExpression(binOp.left);
                tempSlotDepth--;
                // Now x0 = left result
                // Save left to x8 (safe since no more calls)
                gen.emitMoveX0ToX8();  // x8 = left
                // Load right from temp slot
                gen.emitLoadLocal32(myTempSlot);  // x0 = right (from temp slot)
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
                    emitCheckedDiv(binOp.location.filename ? binOp.location.filename : "",
                                   binOp.location.line, binOp.location.column);
                    break;
                case BinaryExpression.Operator.Modulo:
                    emitCheckedMod(binOp.location.filename ? binOp.location.filename : "",
                                   binOp.location.line, binOp.location.column);
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
                    assert(0, "ShiftLeft should be lowered to opShiftLeft call");
                case BinaryExpression.Operator.ShiftRight:
                    assert(0, "ShiftRight should be lowered to opShiftRight call");
                case BinaryExpression.Operator.UnsignedShiftRight:
                    assert(0, "UnsignedShiftRight should be lowered to opUnsignedShiftRight call");
                case BinaryExpression.Operator.LogicalAnd:
                    assert(0, "LogicalAnd should be handled by short-circuit above");
                case BinaryExpression.Operator.LogicalOr:
                    assert(0, "LogicalOr should be handled by short-circuit above");
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
            } else if (unaryOp.operator == UnaryExpression.Operator.BitwiseNot) {
                // ~x
                gen.emit(stencil_not_i32);
            }
        } else if (auto ident = cast(IdentifierExpression)expr) {
            // Load variable from stack
            if (auto info = ident.name in localVars) {
                final switch (info.kind) {
                    case VarKind.struct_:
                    case VarKind.staticArray:
                    case VarKind.slice:
                        // Aggregate types: emit address (pointer) instead of loading value
                        gen.emitStackAddress(info.offset);
                        break;
                    case VarKind.scalar:
                        gen.emitLoadLocal32(info.offset);
                        break;
                }
            } else if (currentMethodStruct !is null) {
                // In a method: check for implicit field access (field without 'this.')
                auto field = currentMethodStruct.getField(ident.name);
                if (field) {
                    // Load this pointer, then load field
                    gen.emitLoadPtr(currentThisOffset);  // x0 = this ptr (64-bit)
                    gen.emitLoadFromPointer(field.offset);  // x0 = this.field
                    return;
                }
                auto symbol = symbolTable.lookupSymbol(ident.name);
                if (symbol && cast(VariableDecl)symbol.declaration)
                    throw new NativeCompileError(
                        "Cannot access module-level variable '" ~ ident.name ~ "' during CTFE",
                        ident.location);
                throw new NativeCompileError("Unknown variable in native backend: " ~ ident.name, ident.location);
            } else {
                auto symbol = symbolTable.lookupSymbol(ident.name);
                if (symbol && cast(VariableDecl)symbol.declaration)
                    throw new NativeCompileError(
                        "Cannot access module-level variable '" ~ ident.name ~ "' during CTFE",
                        ident.location);
                throw new NativeCompileError("Unknown variable in native backend: " ~ ident.name, ident.location);
            }
        } else if (auto assign = cast(AssignmentExpression)expr) {
            // Check for index assignment (arr[i] = value)
            if (auto indexExpr = cast(IndexExpression)assign.left) {
                if (assign.operator == AssignmentExpression.Operator.Assign) {
                    emitIndexAssignment(indexExpr, assign.right);
                    return;
                } else {
                    throw new Exception("Compound index assignment not yet supported in native backend");
                }
            }

            // Check for member expression assignment (c.value = 10)
            if (auto member = cast(MemberExpression)assign.left) {
                compileMemberAssignment(member, assign);
                return;
            }

            auto targetIdent = cast(IdentifierExpression)assign.left;
            if (targetIdent is null) {
                throw new NativeCompileError("Assignment to non-identifier not yet supported in native backend", assign.location);
            }
            
            auto info = targetIdent.name in localVars;
            if (info is null) {
                // In a method: check for implicit field assignment
                if (currentMethodStruct !is null && assign.operator == AssignmentExpression.Operator.Assign) {
                    auto field = currentMethodStruct.getField(targetIdent.name);
                    if (field) {
                        compileExpression(assign.right);  // x0 = value
                        gen.emitMoveX0ToX9();             // x9 = value
                        gen.emitLoadPtr(currentThisOffset);  // x0 = this ptr
                        gen.emitStoreToPointerFromX9(field.offset);  // this.field = x9
                        return;
                    }
                }
                auto symbol = symbolTable.lookupSymbol(targetIdent.name);
                if (symbol && cast(VariableDecl)symbol.declaration)
                    throw new NativeCompileError(
                        "Cannot access module-level variable '" ~ targetIdent.name ~ "' during CTFE",
                        targetIdent.location);
                throw new NativeCompileError("Unknown variable in native backend: " ~ targetIdent.name, targetIdent.location);
            }

            // Handle slice append specially (~=)
            if (assign.operator == AssignmentExpression.Operator.ConcatAssign) {
                if (info.isSlice) {
                    compileSliceAppend(info.offset, assign.right);
                    return;
                } else {
                    throw new Exception("~= only supported on slice types");
                }
            }
            
            if (assign.loweredCall) {
                // Lowered shift compound assignment: emit call, store result
                compileExpression(assign.loweredCall);
                gen.emitStoreLocal32(info.offset);
            } else if (assign.operator == AssignmentExpression.Operator.Assign) {
                // Simple assignment: x = expr
                compileExpression(assign.right);
                gen.emitStoreLocal32(info.offset);
            } else {
                // Compound assignment: x op= expr
                // First compile right side to x0
                compileExpression(assign.right);
                gen.emitMoveX0ToX1();  // x1 = right value
                
                // Load current value to x0
                gen.emitLoadLocal32(info.offset);
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
                        emitCheckedDiv(assign.location.filename ? assign.location.filename : "",
                                       assign.location.line, assign.location.column);
                        break;
                    case AssignmentExpression.Operator.ModuloAssign:
                        emitCheckedMod(assign.location.filename ? assign.location.filename : "",
                                       assign.location.line, assign.location.column);
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
                        assert(0, "<<= should be lowered to opShiftLeft call");
                    case AssignmentExpression.Operator.ShiftRightAssign:
                        assert(0, ">>= should be lowered to opShiftRight call");
                    case AssignmentExpression.Operator.ConcatAssign:
                        // Handled specially above for slices
                        throw new Exception("~= on non-slice not supported");
                    default:
                        break;
                }
                
                // Store result back
                gen.emitStoreLocal32(info.offset);
            }
            // Result of assignment is the assigned value (already in x0)
        } else if (auto call = cast(CallExpression)expr) {
            // Check if this is struct construction
            if (auto funcIdent = cast(IdentifierExpression)call.function_) {
                auto symbol = symbolTable.lookupSymbol(funcIdent.name);
                if (symbol && symbol.kind == SymbolKind.Type) {
                    if (auto structDecl = symbol.type.asStruct()) {
                        // Struct construction: allocate space and init fields
                        compileStructConstruction(structDecl, call.arguments);
                        return;
                    }
                }
                
                // Milestone 89: Handle __writeln - lower to typed write calls
                if (funcIdent.name == "__writeln") {
                    compileWriteln(call.arguments);
                    return;
                }

                // Compiler intrinsics — emit raw opcodes, no function call
                if (funcIdent.name.length > 12 && funcIdent.name[0..12] == "__intrinsic_") {
                    compileIntrinsicCall(funcIdent.name, call.arguments);
                    return;
                }

                // IFTI: use resolved instantiation name if available
                string callName = call.resolvedInstantiation ? call.resolvedInstantiation.name : funcIdent.name;

                // Check if this is a call to a known function
                if (auto labelPtr = callName in functionLabels) {
                    // Check if callee needs arena (shifts user args by 1 register)
                    bool calleeNeedsArena = false;
                    if (auto calleeDecl = callName in functionDecls) {
                        calleeNeedsArena = (*calleeDecl).needsArena;
                    }
                    int arenaShift = calleeNeedsArena ? 1 : 0;

                    if (call.arguments.length + arenaShift > 4) {
                        throw new Exception("Native backend: more than 4 arguments not yet supported");
                    }

                    // Check if any argument contains a function call that would clobber registers
                    bool hasNestedCalls = false;
                    foreach (arg; call.arguments) {
                        if (containsCall(arg)) {
                            hasNestedCalls = true;
                            break;
                        }
                    }

                    if (hasNestedCalls && call.arguments.length > 1) {
                        // Save arguments to temp slots, then load into registers
                        // This prevents register clobbering from nested calls
                        // Use 64-bit store/load — pointer args (slice, struct) need full width
                        size_t argBase = (tempSlot + 7) & ~7;  // 8-byte align
                        size_t[] argSlots;
                        foreach (i, arg; call.arguments) {
                            compileExpression(arg);
                            size_t slot = argBase + (i * 8);
                            gen.emitStorePtr(slot);
                            argSlots ~= slot;
                        }
                        // Load from temp slots into argument registers (reverse order!)
                        // Arena shifts user args: x0 -> x(0+shift), etc.
                        for (long i = cast(long)argSlots.length - 1; i >= 0; i--) {
                            gen.emitLoadPtr(argSlots[cast(size_t)i]);
                            switch (cast(int)i + arenaShift) {
                                case 0: break;  // already in x0
                                case 1: gen.emitMoveX0ToX1(); break;
                                case 2: gen.emitMoveX0ToX2(); break;
                                case 3: gen.emitMoveX0ToX3(); break;
                                default: assert(0, "argument register > 3");
                            }
                        }
                    } else {
                        // No nested calls - use the faster direct approach
                        // Compile arguments in reverse order into their target registers
                        for (long i = cast(long)call.arguments.length - 1; i >= 0; i--) {
                            compileExpression(call.arguments[i]);
                            // Move x0 to target register (shifted by arena)
                            switch (cast(int)i + arenaShift) {
                                case 0: break;  // already in x0
                                case 1: gen.emitMoveX0ToX1(); break;
                                case 2: gen.emitMoveX0ToX2(); break;
                                case 3: gen.emitMoveX0ToX3(); break;
                                default: assert(0, "argument register > 3");
                            }
                        }
                    }

                    // Load arena into x0 if callee needs it
                    if (calleeNeedsArena) {
                        gen.emitLoadPtr(currentFunctionArenaOffset);
                    }

                    // Emit the call (BL instruction)
                    gen.emitCall(*labelPtr);
                    // Result is in x0
                    return;
                }
                
                // Milestone 88/90: Check if this is a host function call
                ulong hostSlot = hostFunctions.getFunctionSlotAddress(funcIdent.name);
                if (hostSlot != 0) {
                    if (call.arguments.length > 3) {
                        throw new Exception("Native backend: host functions support max 3 arguments (x0 reserved for context)");
                    }
                    
                    // Compile arguments in reverse order into x0-x2
                    // emitHostCall will shift them to x1-x3 and inject context in x0
                    for (long i = cast(long)call.arguments.length - 1; i >= 0; i--) {
                        compileExpression(call.arguments[i]);
                        switch (i) {
                            case 0: break;  // already in x0
                            case 1: gen.emitMoveX0ToX1(); break;
                            case 2: gen.emitMoveX0ToX2(); break;
                            default: break;
                        }
                    }
                    
                    // Emit host call with context injection
                    ulong contextSlot = hostFunctions.getContextSlotAddress();
                    gen.emitHostCall(hostSlot, contextSlot);
                    // Result is in x0
                    return;
                }
            }
            // Check for method call: obj.method()
            if (auto memberCall = cast(MemberExpression)call.function_) {
                emitMethodCall(memberCall, call.arguments);
                return;
            }
            throw new Exception("Function calls not yet supported in native backend: " ~
                (cast(IdentifierExpression)call.function_ ? (cast(IdentifierExpression)call.function_).name : "unknown"));
        } else if (auto member = cast(MemberExpression)expr) {
            // Check for slice.length first
            if (member.memberName == "length") {
                if (auto ident = cast(IdentifierExpression)member.object) {
                    if (auto varInfo = ident.name in localVars) {
                        if (varInfo.isSlice) {
                            gen.emitLoadLocal32(varInfo.offset + NativeSliceLayout.LENGTH_OFFSET);
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
                if (auto varInfo = ident.name in localVars) {
                    size_t totalOffset = varInfo.offset + field.offset;
                    // Aggregate fields: emit address (for nested access or passing)
                    // Scalar fields: load the value
                    if (field.type.isAggregate()) {
                        gen.emitStackAddress(totalOffset);
                    } else {
                        gen.emitLoadLocal32(totalOffset);
                    }
                    return;
                }
            }
            
            // For other expressions (e.g., nested access), compile to get pointer
            compileExpression(member.object);
            // x0 now has pointer to struct
            size_t fieldOffset = field.offset;
            // Aggregate fields: compute address (for further nested access)
            // Scalar fields: load the value
            if (field.type.isAggregate()) {
                // Add offset to pointer: x0 = x0 + fieldOffset
                if (fieldOffset > 0) {
                    gen.emitMoveX0ToX1();
                    gen.emitImm32(stencil_load_imm32, cast(int)fieldOffset);
                    gen.emit(stencil_add_i64);  // 64-bit ptr arithmetic
                }
                // x0 now has address of nested aggregate
            } else {
                gen.emitLoadFromPointer(fieldOffset);
            }
        } else if (auto arrLit = cast(ArrayLiteralExpression)expr) {
            // Array literal: [1, 2, 3]
            // Allocate space for data + slice struct
            uint elemCount = cast(uint)arrLit.elements.length;
            uint dataSize = elemCount * 4;  // 4 bytes per int element
            enum sliceSize = NativeSliceLayout.sizeof;  // ptr, length, capacity
            
            size_t dataOffset = nextLocalOffset;
            nextLocalOffset += dataSize;
            size_t sliceOffset = (nextLocalOffset + 7) & ~7;  // 8-byte align for 64-bit ptr field
            nextLocalOffset = sliceOffset + sliceSize;
            assert(nextLocalOffset <= tempSlot,
                "Frame overflow in array literal: nextLocalOffset exceeds tempSlot");

            // Initialize data elements
            foreach (i, elem; arrLit.elements) {
                compileExpression(elem);
                gen.emitStoreLocal32(dataOffset + i * 4);
            }
            
            // Initialize slice struct
            // ptr = sp + dataOffset
            gen.emitLoadStackPointer();
            gen.emitMoveX0ToX1();
            gen.emitImm32(stencil_load_imm32, cast(int)dataOffset);
            gen.emit(stencil_add_i64);  // 64-bit ptr arithmetic
            gen.emitStorePtr(sliceOffset);  // store 64-bit ptr

            // length = elemCount
            gen.emitImm32(stencil_load_imm32, cast(int)elemCount);
            gen.emitStoreLocal32(sliceOffset + NativeSliceLayout.LENGTH_OFFSET);  // store length

            // capacity = elemCount
            gen.emitImm32(stencil_load_imm32, cast(int)elemCount);
            gen.emitStoreLocal32(sliceOffset + NativeSliceLayout.CAPACITY_OFFSET);  // store capacity

            // Leave pointer to slice struct in x0
            gen.emitLoadStackPointer();
            gen.emitMoveX0ToX1();
            gen.emitImm32(stencil_load_imm32, cast(int)sliceOffset);
            gen.emit(stencil_add_i64);  // 64-bit ptr arithmetic
            
        } else if (auto indexExpr = cast(IndexExpression)expr) {
            // Array/slice indexing: arr[i]
            if (auto ident = cast(IdentifierExpression)indexExpr.array) {
                if (auto info = ident.name in localVars) {
                    final switch (info.kind) {
                        case VarKind.staticArray:
                            // Static array: elements stored inline at offset
                            uint saElemSz = info.staticArrayElemSize;
                            // For constant index, load directly (scalars only)
                            if (saElemSz <= 4) {
                                if (auto indexLit = cast(LiteralExpression)indexExpr.index) {
                                    if (indexLit.value.type == typeid(long)) {
                                        uint idx = cast(uint)indexLit.value.get!long();
                                        gen.emitLoadLocal32(info.offset + idx * saElemSz);
                                        return;
                                    }
                                }
                            }
                            // For dynamic index (or aggregate elements), compute address
                            compileExpression(indexExpr.index);
                            gen.emitMoveX0ToX1();  // x1 = index
                            gen.emitImm32(stencil_load_imm32, saElemSz);
                            gen.emit(stencil_mul_i32);  // x0 = index * elemSize
                            gen.emitMoveX0ToX1();  // x1 = byte offset
                            gen.emitStackAddress(info.offset);  // x0 = base address
                            gen.emit(stencil_add_i64);  // x0 = element address (64-bit ptr)
                            // Aggregate elements: leave address in x0
                            if (saElemSz <= 4)
                                gen.emitLoadFromPointer(0);
                            return;

                        case VarKind.slice:
                            // Dynamic array (slice): { ptr: i64, length: i32, capacity: i32 }
                            compileExpression(indexExpr.index);
                            // x0 = index

                            // Bounds check: 0 <= index < length
                            emitBoundsCheck(info.offset,
                                            indexExpr.location.filename ? indexExpr.location.filename : "",
                                            indexExpr.location.line, indexExpr.location.column);
                            // x0 still = index

                            // Compute index * elemSize
                            gen.emitMoveX0ToX1();  // x1 = index
                            gen.emitImm32(stencil_load_imm32, info.elemSize);
                            gen.emit(stencil_mul_i32);  // x0 = index * elemSize
                            gen.emitMoveX0ToX1();  // x1 = byte offset

                            // Load 64-bit ptr from slice struct (offset 0)
                            gen.emitLoadPtr(info.offset);  // x0 = ptr (64-bit!)

                            // Compute address: ptr + byte offset
                            gen.emit(stencil_add_i64);  // 64-bit ptr arithmetic

                            // Aggregate elements: leave address in x0
                            if (info.elemSize <= 4) {
                                if (info.elemSize == 1)
                                    gen.emitLoadByteFromPointer(0);
                                else
                                    gen.emitLoadFromPointer(0);
                            }
                            return;

                        case VarKind.struct_:
                            assert(0, "Cannot index struct variable: " ~ ident.name);
                        case VarKind.scalar:
                            assert(0, "Cannot index scalar variable: " ~ ident.name);
                    }
                }
            }
            throw new Exception("Array indexing only supported for local variables");
        } else if (auto castExpr = cast(CastExpression)expr) {
            // Most casts are no-ops at native level (everything is 32/64-bit)
            // Just compile the inner expression
            // Note: class→interface casts would need special handling when classes are supported
            compileExpression(castExpr.expression);
        } else if (auto sliceExpr = cast(SliceExpression)expr) {
            // Slice expression: source[start..end]
            // Create a temp slice struct on the stack and return its address
            auto sourceIdent = cast(IdentifierExpression)sliceExpr.array;
            if (!sourceIdent)
                throw new Exception("Complex slice source not supported in native backend");

            auto info = sourceIdent.name in localVars;
            if (info is null || (!info.isSlice && !info.isStaticArray))
                throw new Exception("Can only slice array-like variables in native backend");

            uint elemSize = info.elemSize;
            size_t tempOffset = (nextLocalOffset + 7) & ~7;  // 8-byte align for 64-bit ptr store
            nextLocalOffset = tempOffset + NativeSliceLayout.sizeof;
            assert(nextLocalOffset <= tempSlot,
                "Frame overflow in slice expression: nextLocalOffset exceeds tempSlot");

            // Compute new ptr = base + start * elemSize
            if (info.isSlice) {
                gen.emitLoadPtr(info.offset);  // load 64-bit ptr from slice struct
            } else {
                gen.emitStackAddress(info.offset);  // static array: stack address IS data
            }
            gen.emitMoveX0ToX9();  // x9 = source.ptr

            // Compute start * elemSize
            compileExpression(sliceExpr.start);
            gen.emitMoveX0ToX1();  // x1 = start
            gen.emitImm32(stencil_load_imm32, elemSize);
            gen.emit(stencil_mul_i32);  // x0 = start * elemSize

            // ptr + start * elemSize (64-bit add: x9 + x0)
            gen.emitMoveX0ToX1();  // x1 = byte offset
            gen.emitMoveX9ToX0();  // x0 = source.ptr
            gen.emit(stencil_add_i64);  // x0 = new ptr (64-bit)
            gen.emitStorePtr(tempOffset);  // store 64-bit ptr

            // Compute length = end - start
            compileExpression(sliceExpr.end);
            gen.emitMoveX0ToX1();  // x1 = end
            compileExpression(sliceExpr.start);
            // x0 = start, x1 = end → need end - start
            // Swap: we need x0=end, x1=start
            gen.emitMoveX0ToX9();  // x9 = start
            gen.emitMoveX1ToX0();  // x0 = end
            gen.emitMoveX9ToX1();  // x1 = start
            gen.emit(stencil_sub_i32);  // x0 = end - start
            gen.emitStoreLocal32(tempOffset + NativeSliceLayout.LENGTH_OFFSET);

            // capacity = length (reload)
            compileExpression(sliceExpr.end);
            gen.emitMoveX0ToX1();
            compileExpression(sliceExpr.start);
            gen.emitMoveX0ToX9();
            gen.emitMoveX1ToX0();
            gen.emitMoveX9ToX1();
            gen.emit(stencil_sub_i32);
            gen.emitStoreLocal32(tempOffset + NativeSliceLayout.CAPACITY_OFFSET);

            // Return address of temp slice struct
            gen.emitStackAddress(tempOffset);
        } else if (auto traits = cast(TraitsExpression)expr) {
            traits.evaluate();
            gen.emitImm32(stencil_load_imm32, traits.boolResult ? 1 : 0);
        } else if (auto isExpr = cast(IsExpression)expr) {
            gen.emitImm32(stencil_load_imm32, isExpr.boolResult ? 1 : 0);
        } else if (auto tmplInst = cast(TemplateInstantiationExpression)expr) {
            // Struct template construction: Pair!(int, int)(10, 20)
            if (tmplInst.resolvedStructInstantiation) {
                compileStructConstruction(tmplInst.resolvedStructInstantiation, tmplInst.callArguments);
                return;
            }

            // Template instantiation call — emit like a regular call using the mangled name
            auto inst = tmplInst.resolvedInstantiation;
            if (!inst)
                throw new Exception("Template instantiation not resolved: " ~ tmplInst.templateName);

            auto labelPtr = inst.name in functionLabels;
            if (!labelPtr)
                throw new Exception("Template instantiation label not found: " ~ inst.name);

            // Check if callee needs arena
            bool calleeNeedsArena = inst.needsArena;
            int arenaShift = calleeNeedsArena ? 1 : 0;

            // Compile arguments into registers (shifted by arena)
            for (long i = cast(long)tmplInst.callArguments.length - 1; i >= 0; i--) {
                compileExpression(tmplInst.callArguments[i]);
                switch (cast(int)i + arenaShift) {
                    case 0: break;
                    case 1: gen.emitMoveX0ToX1(); break;
                    case 2: gen.emitMoveX0ToX2(); break;
                    case 3: gen.emitMoveX0ToX3(); break;
                    default: assert(0, "argument register > 3");
                }
            }

            // Load arena into x0 if callee needs it
            if (calleeNeedsArena) {
                gen.emitLoadPtr(currentFunctionArenaOffset);
            }

            gen.emitCall(*labelPtr);
        } else {
            throw new Exception("Expression type not yet supported in native backend: " ~
                typeid(expr).toString());
        }
    }
    
    /**
     * Emit index assignment: arr[i] = value
     */
    private void emitIndexAssignment(IndexExpression indexExpr, Expression value) {
        auto ident = cast(IdentifierExpression)indexExpr.array;
        if (ident is null)
            throw new Exception("Index assignment only supported for local variables in native backend");

        auto info = ident.name in localVars;
        if (info is null)
            throw new Exception("Unknown variable in native backend: " ~ ident.name);

        uint es = info.elemSize;
        final switch (info.kind) {
            case VarKind.staticArray:
                if (es > 4) {
                    // Aggregate element: save 64-bit addresses to 8-byte-aligned temp slots
                    size_t dstTemp = (tempSlot + 24 + 7) & ~cast(size_t)7;
                    size_t srcTemp = dstTemp + 8;
                    compileExpression(indexExpr.index);  // x0 = index
                    gen.emitMoveX0ToX1();
                    gen.emitImm32(stencil_load_imm32, es);
                    gen.emit(stencil_mul_i32);  // x0 = index * elemSize
                    gen.emitMoveX0ToX1();
                    gen.emitStackAddress(info.offset);
                    gen.emit(stencil_add_i64);  // x0 = dst address (64-bit ptr)
                    gen.emitStorePtr(dstTemp);
                    compileExpression(value);   // x0 = src address (64-bit)
                    gen.emitStorePtr(srcTemp);
                    // Copy es bytes: 4 bytes at a time
                    for (uint off = 0; off < es; off += 4) {
                        gen.emitLoadPtr(srcTemp);        // x0 = src (64-bit ptr)
                        gen.emitLoadFromPointer(off);      // x0 = *(src + off)
                        gen.emitMoveX0ToX1();              // x1 = value
                        gen.emitLoadPtr(dstTemp);        // x0 = dst (64-bit ptr)
                        gen.emitStoreToPointer(off);       // *(dst + off) = x1
                    }
                    return;
                }
                // Scalar: constant index optimization
                if (auto indexLit = cast(LiteralExpression)indexExpr.index) {
                    if (indexLit.value.type == typeid(long)) {
                        uint idx = cast(uint)indexLit.value.get!long();
                        compileExpression(value);  // x0 = value
                        gen.emitStoreLocal32(info.offset + idx * es);
                        return;
                    }
                }
                // Scalar: dynamic index
                compileExpression(value);  // x0 = value
                gen.emitMoveX0ToX9();      // x9 = value
                compileExpression(indexExpr.index);  // x0 = index
                gen.emitMoveX0ToX1();
                gen.emitImm32(stencil_load_imm32, es);
                gen.emit(stencil_mul_i32);  // x0 = index * elemSize
                gen.emitMoveX0ToX1();
                gen.emitStackAddress(info.offset);
                gen.emit(stencil_add_i64);  // x0 = target address (64-bit ptr)
                gen.emitStoreToPointerFromX9(0);
                return;

            case VarKind.slice:
                if (es > 4) {
                    // Aggregate element: save 64-bit addresses to 8-byte-aligned temp slots
                    size_t dstTemp = (tempSlot + 24 + 7) & ~cast(size_t)7;
                    size_t srcTemp = dstTemp + 8;
                    compileExpression(indexExpr.index);  // x0 = index
                    gen.emitMoveX0ToX1();
                    gen.emitImm32(stencil_load_imm32, es);
                    gen.emit(stencil_mul_i32);
                    gen.emitMoveX0ToX1();
                    gen.emitLoadPtr(info.offset);  // x0 = slice ptr (64-bit)
                    gen.emit(stencil_add_i64);  // x0 = dst address (64-bit ptr)
                    gen.emitStorePtr(dstTemp);
                    compileExpression(value);   // x0 = src address (64-bit)
                    gen.emitStorePtr(srcTemp);
                    for (uint off = 0; off < es; off += 4) {
                        gen.emitLoadPtr(srcTemp);
                        gen.emitLoadFromPointer(off);
                        gen.emitMoveX0ToX1();
                        gen.emitLoadPtr(dstTemp);
                        gen.emitStoreToPointer(off);
                    }
                    return;
                }
                // Scalar: store single value
                compileExpression(value);  // x0 = value
                gen.emitMoveX0ToX9();
                compileExpression(indexExpr.index);  // x0 = index
                gen.emitMoveX0ToX1();
                gen.emitImm32(stencil_load_imm32, es);
                gen.emit(stencil_mul_i32);
                gen.emitMoveX0ToX1();
                gen.emitLoadPtr(info.offset);  // x0 = slice ptr (64-bit)
                gen.emit(stencil_add_i64);  // x0 = target address (64-bit ptr)
                gen.emitStoreToPointerFromX9(0);
                return;

            case VarKind.struct_:
                assert(0, "Cannot index-assign struct variable: " ~ ident.name);
            case VarKind.scalar:
                assert(0, "Cannot index-assign scalar variable: " ~ ident.name);
        }
    }

    /**
     * Emit a struct method call: obj.method(args)
     * Passes 'this' pointer (address of obj) as first argument in x0,
     * then user arguments in x1, x2, etc.
     */
    private void emitMethodCall(MemberExpression memberExpr, Expression[] args) {
        // Handle nested MemberExpression objects (e.g., obj.field.method() from alias-this)
        if (auto objMember = cast(MemberExpression)memberExpr.object) {
            auto innerStruct = getStructDeclFromExpr(objMember);
            if (innerStruct) {
                FunctionDecl method = null;
                foreach (member; innerStruct.members) {
                    if (auto funcDecl = cast(FunctionDecl)member) {
                        if (funcDecl.name == memberExpr.memberName && funcDecl.isMethod) {
                            method = funcDecl;
                            break;
                        }
                    }
                }
                if (method) {
                    string mangledMethodName = getMangledName(method);
                    auto labelPtr = mangledMethodName in functionLabels;
                    if (labelPtr is null)
                        throw new Exception("Method not compiled: " ~ mangledMethodName);

                    bool methodNeedsArena = method.needsArena;
                    int methodArenaShift = methodNeedsArena ? 1 : 0;

                    // Emit arguments into registers (shifted by arena)
                    emitMethodArgs(args, methodArenaShift);

                    // Load arena into x1 if method needs it
                    if (methodNeedsArena) {
                        gen.emitLoadPtr(currentFunctionArenaOffset);
                        gen.emitMoveX0ToX1();
                    }

                    // Compute 'this' pointer: address of nested member
                    compileExpression(objMember);  // leaves address in x0

                    gen.emitCall(*labelPtr);
                    return;
                }
            }
            throw new Exception("Cannot resolve method '" ~ memberExpr.memberName ~ "' on nested member expression");
        }

        auto objIdent = cast(IdentifierExpression)memberExpr.object;
        if (!objIdent)
            throw new Exception("Method call on non-identifier object not yet supported in native backend");

        // Look up the object to find its struct type
        auto info = objIdent.name in localVars;
        if (info is null)
            throw new Exception("Unknown variable for method call in native backend: " ~ objIdent.name);

        StructDecl structDecl = info.structDecl;
        if (structDecl is null)
            throw new Exception("Method call on non-struct variable: " ~ objIdent.name);

        // Find the method in the struct's members
        FunctionDecl method = null;
        foreach (member; structDecl.members) {
            if (auto funcDecl = cast(FunctionDecl)member) {
                if (funcDecl.name == memberExpr.memberName && funcDecl.isMethod) {
                    method = funcDecl;
                    break;
                }
            }
        }

        if (method is null)
            throw new Exception("Struct '" ~ structDecl.name ~ "' has no method '" ~ memberExpr.memberName ~ "'");

        // Look up the mangled function label
        string mangledMethodName = getMangledName(method);
        auto labelPtr = mangledMethodName in functionLabels;
        if (labelPtr is null)
            throw new Exception("Method not compiled: " ~ mangledMethodName);

        bool methodNeedsArena = method.needsArena;
        int methodArenaShift = methodNeedsArena ? 1 : 0;

        if (args.length + methodArenaShift > 3)
            throw new Exception("Native backend: methods support max 3 user arguments (x0 reserved for this)");

        // Emit arguments into registers (shifted by arena)
        emitMethodArgs(args, methodArenaShift);

        // Load arena into x1 if method needs it
        if (methodNeedsArena) {
            gen.emitLoadPtr(currentFunctionArenaOffset);
            gen.emitMoveX0ToX1();
        }

        // Load 'this' pointer into x0 (stack address of the struct)
        gen.emitStackAddress(info.offset);

        // Emit the call
        gen.emitCall(*labelPtr);
        // Result is in x0
    }

    /// Emit method call arguments into registers.
    /// arenaShift=0: args go into x1, x2, x3 (no arena)
    /// arenaShift=1: args go into x2, x3, x4 (x1 reserved for arena)
    private void emitMethodArgs(Expression[] args, int arenaShift = 0) {
        if (args.length + arenaShift > 3)
            throw new Exception("Native backend: methods support max 3 user arguments (x0 reserved for this)");

        // Check if any argument contains a function call that would clobber registers
        bool hasNestedCalls = false;
        foreach (arg; args) {
            if (containsCall(arg)) {
                hasNestedCalls = true;
                break;
            }
        }

        if (hasNestedCalls && args.length > 1) {
            // Save arguments to temp slots, then load into registers
            size_t[] argSlots;
            foreach (i, arg; args) {
                compileExpression(arg);
                size_t slot = tempSlot + (i * 4);
                gen.emitStoreLocal32(slot);
                argSlots ~= slot;
            }
            // Load from temp slots into registers (reverse order to not clobber)
            for (long i = cast(long)argSlots.length - 1; i >= 0; i--) {
                gen.emitLoadLocal32(argSlots[cast(size_t)i]);
                switch (cast(int)i + 1 + arenaShift) {
                    case 1: gen.emitMoveX0ToX1(); break;
                    case 2: gen.emitMoveX0ToX2(); break;
                    case 3: gen.emitMoveX0ToX3(); break;
                    default: assert(0, "method argument register > 3");
                }
            }
        } else {
            // No nested calls - direct register assignment (reverse order)
            for (long i = cast(long)args.length - 1; i >= 0; i--) {
                compileExpression(args[i]);
                switch (cast(int)i + 1 + arenaShift) {
                    case 1: gen.emitMoveX0ToX1(); break;
                    case 2: gen.emitMoveX0ToX2(); break;
                    case 3: gen.emitMoveX0ToX3(); break;
                    default: assert(0, "method argument register > 3");
                }
            }
        }
    }

    /**
     * Emit call stack push - store call frame data and call __ctfe_push_call
     */
    private void emitPushCall(string funcName, string fileName, uint line) {
        import codegen.native.arm64_codegen : CallFrameData;
        
        // Store function name and file name in data section
        ubyte* namePtr = dataSection.addString(funcName);
        ubyte* filePtr = dataSection.addString(fileName);
        if (namePtr is null || filePtr is null) return;  // Out of space, skip tracking
        
        // Build CallFrameData struct in data section
        CallFrameData frameData;
        frameData.namePtr = cast(ulong)namePtr;
        frameData.nameLen = cast(uint)funcName.length;
        frameData.filePtr = cast(ulong)filePtr;
        frameData.fileLen = cast(uint)fileName.length;
        frameData.line = line;
        
        ubyte* framePtr = dataSection.addData((cast(ubyte*)&frameData)[0..CallFrameData.sizeof]);
        if (framePtr is null) return;
        
        // Load frame pointer into x0
        gen.emitLoadImm64(cast(ulong)framePtr);  // x0 = framePtr
        
        ulong slot = hostFunctions.getFunctionSlotAddress("__ctfe_push_call");
        ulong ctxSlot = hostFunctions.getContextSlotAddress();
        gen.emitHostCall(slot, ctxSlot);
    }
    
    /**
     * Emit call stack pop - call __ctfe_pop_call
     */
    private void emitPopCall() {
        // No arguments needed, emitHostCall will inject context
        ulong slot = hostFunctions.getFunctionSlotAddress("__ctfe_pop_call");
        ulong ctxSlot = hostFunctions.getContextSlotAddress();
        gen.emitHostCall(slot, ctxSlot);
    }
    
    /**
     * Emit inline call stack push - writes directly to data section, no FFI
     * Uses x8, x9, x10, x11, x12, x13 as scratch (saves/restores x0)
     */
    private void emitInlinePushCall(string funcName, string fileName, uint line) {
        import codegen.native.codegen_interface : InlineFrame, INLINE_STACK_DEPTH_OFFSET,
            INLINE_STACK_MAX_DEPTH, INLINE_STACK_FRAMES_OFFSET, INLINE_FRAME_SIZE;
        import std.stdio : writefln;
        
        // Add strings to data section, get their offsets
        size_t nameOffset = dataSection.bytesUsed;
        auto namePtr = dataSection.addString(funcName);
        if (namePtr is null) return;
        
        size_t fileOffset = dataSection.bytesUsed;
        auto filePtr = dataSection.addString(fileName);
        if (filePtr is null) return;
        
        // Build InlineFrame in data section
        InlineFrame frame;
        frame.nameOffset = cast(uint)nameOffset;
        frame.nameLen = cast(uint)funcName.length;
        frame.fileOffset = cast(uint)fileOffset;
        frame.fileLen = cast(uint)fileName.length;
        frame.line = line;
        frame.column = 0;
        
        size_t frameDataOffset = dataSection.bytesUsed;
        auto framePtr = dataSection.addData((cast(ubyte*)&frame)[0..InlineFrame.sizeof]);
        if (framePtr is null) return;
        
        // Save x0 (might contain pointer — must use 64-bit store)
        gen.emitStorePtr(tempSlot);

        // Load data section base into x10
        gen.emitLoadImm64(cast(ulong)dataSection.base);
        gen.emitMoveX0ToX10();

        // Emit inline push code
        gen.emitInlineStackPush(cast(uint)frameDataOffset);

        // Restore x0
        gen.emitLoadPtr(tempSlot);
    }
    
    /**
     * Emit inline call stack pop - decrements depth in data section, no FFI
     * Uses x8, x10 as scratch (does NOT touch x0, safe for return values)
     */
    private void emitInlinePopCall() {
        // Save x0 (return value) to stack FIRST, before we clobber it
        // Use tempSlot+8 to avoid conflicts with push save slot at tempSlot+0
        gen.emitStorePtr(tempSlot + 8);

        // Load data section base into x10 (clobbers x0, but we saved it)
        gen.emitLoadImm64(cast(ulong)dataSection.base);
        gen.emitMoveX0ToX10();

        // Emit inline pop code (uses x8, so we can't save return value there)
        gen.emitInlineStackPop();

        // Restore x0 (return value) from stack
        gen.emitLoadPtr(tempSlot + 8);
    }
    
    /**
     * Emit bounds check: if index < 0 or index >= length, call __ctfe_trap.
     * Assumes: index in x0
     * Slice layout: { ptr: i64, length: i32, capacity: i32 } at sliceOffset (16 bytes)
     * Preserves: x0 (index)
     */
    private void emitBoundsCheck(size_t sliceOffset, string fileName, uint line, uint column) {
        import codegen.native.arm64_codegen : ErrorLocData;
        
        auto errorLabel = gen.newLabel();
        auto okLabel = gen.newLabel();
        
        // Use depth-aware temp slot; +16 reserves first 16 bytes for inline push/pop saves
        size_t myTempSlot = tempSlot + 16 + (tempSlotDepth * 4);
        tempSlotDepth++;
        
        // Save index to temp (we need it after bounds check)
        gen.emitStoreLocal32(myTempSlot);
        
        // Load length from slice (offset 8 = after 64-bit ptr)
        gen.emitLoadLocal32(sliceOffset + NativeSliceLayout.LENGTH_OFFSET);  // x0 = length
        gen.emitMoveX0ToX1();  // x1 = length
        
        // Reload index
        gen.emitLoadLocal32(myTempSlot);  // x0 = index
        
        // Compare: if index < length (unsigned), OK; else error
        gen.emit(stencil_lt_u32);  // x0 = (index < length) ? 1 : 0
        gen.emitBranchIfNonZero(okLabel);  // branch if index < length
        
        // Out of bounds - call trap with location
        ubyte* filePtr = dataSection.addString(fileName);
        ErrorLocData errData;
        errData.filePtr = cast(ulong)filePtr;
        errData.fileLen = cast(uint)fileName.length;
        errData.line = line;
        errData.column = column;
        errData.errorKind = cast(uint)CTFEErrorKind.OutOfBounds;
        
        ubyte* errLocPtr = dataSection.addData((cast(ubyte*)&errData)[0..ErrorLocData.sizeof]);
        gen.emitLoadImm64(cast(ulong)errLocPtr);
        
        ulong trapSlot = hostFunctions.getFunctionSlotAddress("__ctfe_trap");
        ulong contextSlot = hostFunctions.getContextSlotAddress();
        gen.emitHostCall(trapSlot, contextSlot);
        
        gen.bindLabel(okLabel);
        // Restore index to x0
        gen.emitLoadLocal32(myTempSlot);  // x0 = index
        
        tempSlotDepth--;
    }
    
    /**
     * Emit checked division: if divisor is 0, call __ctfe_trap.
     * Assumes: dividend in x0, divisor in x1
     * Result: quotient in x0
     */
    private void emitCheckedDiv(string fileName, uint line, uint column) {
        import codegen.native.arm64_codegen : ErrorLocData;
        
        auto errorLabel = gen.newLabel();
        auto doneLabel = gen.newLabel();
        
        // CBZ x1, error  (branch if divisor is zero)
        gen.emitBranchIfZeroX1(errorLabel);
        
        // SDIV x0, x0, x1
        gen.emit(stencil_div_i32);
        
        // B done (skip error handler)
        gen.emitBranch(doneLabel);
        
        // .Ldiv_error:
        gen.bindLabel(errorLabel);
        
        // Build ErrorLocData in data section
        ubyte* filePtr = dataSection.addString(fileName);
        ErrorLocData errData;
        errData.filePtr = cast(ulong)filePtr;
        errData.fileLen = cast(uint)fileName.length;
        errData.line = line;
        errData.column = column;
        errData.errorKind = cast(uint)CTFEErrorKind.DivByZero;
        
        ubyte* errLocPtr = dataSection.addData((cast(ubyte*)&errData)[0..ErrorLocData.sizeof]);
        
        // Load error location pointer into x0
        gen.emitLoadImm64(cast(ulong)errLocPtr);
        
        // Call __ctfe_trap(ctx, errorLocPtr)
        ulong trapSlot = hostFunctions.getFunctionSlotAddress("__ctfe_trap");
        ulong contextSlot = hostFunctions.getContextSlotAddress();
        gen.emitHostCall(trapSlot, contextSlot);
        // longjmp happens inside __ctfe_trap, we never return here
        
        // .Ldiv_done:
        gen.bindLabel(doneLabel);
    }
    
    /**
     * Emit checked modulo: if divisor is 0, call __ctfe_trap.
     * Assumes: dividend in x0, divisor in x1
     * Result: remainder in x0
     */
    private void emitCheckedMod(string fileName, uint line, uint column) {
        import codegen.native.arm64_codegen : ErrorLocData;
        
        auto errorLabel = gen.newLabel();
        auto doneLabel = gen.newLabel();
        
        gen.emitBranchIfZeroX1(errorLabel);
        gen.emit(stencil_mod_i32);
        gen.emitBranch(doneLabel);
        
        gen.bindLabel(errorLabel);
        
        // Build ErrorLocData in data section
        ubyte* filePtr = dataSection.addString(fileName);
        ErrorLocData errData;
        errData.filePtr = cast(ulong)filePtr;
        errData.fileLen = cast(uint)fileName.length;
        errData.line = line;
        errData.column = column;
        errData.errorKind = cast(uint)CTFEErrorKind.DivByZero;
        
        ubyte* errLocPtr = dataSection.addData((cast(ubyte*)&errData)[0..ErrorLocData.sizeof]);
        gen.emitLoadImm64(cast(ulong)errLocPtr);
        
        ulong trapSlot = hostFunctions.getFunctionSlotAddress("__ctfe_trap");
        ulong contextSlot = hostFunctions.getContextSlotAddress();
        gen.emitHostCall(trapSlot, contextSlot);
        
        gen.bindLabel(doneLabel);
    }
    
    /**
     * Compile struct construction: allocate space on stack, initialize fields
     */
    private void compileStructConstruction(StructDecl structDecl, Expression[] args) {
        // Use temp slot area for struct (don't grow nextLocalOffset during emission)
        // tempSlot + 16 onwards is available for struct construction temps
        size_t structSize = structDecl.structSize;
        size_t structOffset = tempSlot + 16;  // After other temp slots
        import std.format : format;
        assert(structOffset + structSize <= totalLocalBytes,
            format("Struct construction temp overflows frame: offset=%d size=%d frame=%d",
                structOffset, structSize, totalLocalBytes));
        assert(structDecl.fields.length > 0,
            "Struct '" ~ structDecl.name ~ "' has no fields");
        
        // Initialize each field from arguments
        for (size_t i = 0; i < structDecl.fields.length && i < args.length; i++) {
            auto field = structDecl.fields[i];
            size_t fieldOffset = structOffset + field.offset;
            
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
        gen.emit(stencil_add_i64);  // 64-bit ptr arithmetic
        // Now x0 = pointer to struct
    }
    
    /**
     * Compile slice initialization from array literal directly to a stack location.
     * Native slice layout: { ptr: i64, length: i32, capacity: i32 } = NativeSliceLayout.sizeof bytes
     * (Unlike WASM which uses 32-bit pointers, native ARM64 needs 64-bit)
     */
    private void compileSliceInit(size_t sliceOffset, ArrayLiteralExpression arrLit) {
        uint elemCount = cast(uint)arrLit.elements.length;
        uint dataSize = elemCount * 4;  // 4 bytes per int element
        
        // Data goes right after the 16-byte slice struct
        size_t dataOffset = sliceOffset + 16;
        
        // Initialize data elements
        foreach (i, elem; arrLit.elements) {
            compileExpression(elem);
            gen.emitStoreLocal32(dataOffset + i * 4);
        }
        
        // Initialize slice struct at sliceOffset
        // ptr = sp + dataOffset (64-bit pointer!)
        gen.emitLoadStackPointer();
        gen.emitMoveX0ToX1();
        gen.emitImm32(stencil_load_imm32, cast(int)dataOffset);
        gen.emit(stencil_add_i64);  // 64-bit ptr arithmetic
        gen.emitStorePtr(sliceOffset);  // store 64-bit ptr
        
        // length = elemCount (32-bit at offset 8)
        gen.emitImm32(stencil_load_imm32, cast(int)elemCount);
        gen.emitStoreLocal32(sliceOffset + NativeSliceLayout.LENGTH_OFFSET);  // store length
        
        // capacity = elemCount (32-bit at offset 12)
        gen.emitImm32(stencil_load_imm32, cast(int)elemCount);
        gen.emitStoreLocal32(sliceOffset + NativeSliceLayout.CAPACITY_OFFSET);  // store capacity
    }
    
    /**
     * Compile import() initialization for a slice variable.
     * Milestone 86: Native backend import() support.
     * 
     * Reads the file at compile time, stores contents in dataSection,
     * and initializes the slice to point to that data.
     */
    private void compileImportInit(size_t sliceOffset, ImportExpression importExpr) {
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
            throw new Exception("import(): file not found: " ~ filename);
        }
        
        // Read the file
        ubyte[] fileData = cast(ubyte[])read(fullPath);
        uint len = cast(uint)fileData.length;
        
        // Add file data to the data section (returns host pointer)
        ubyte* dataPtr = dataSection.addData(fileData);
        if (dataPtr is null) {
            throw new Exception("import(): data section full");
        }
        
        // Initialize slice struct at sliceOffset
        // Native slice layout: { ptr: i64, length: i32, capacity: i32 } = NativeSliceLayout.sizeof bytes
        
        // ptr = dataPtr (64-bit host pointer)
        gen.emitLoadImm64(cast(ulong)dataPtr);
        gen.emitStorePtr(sliceOffset);  // store 64-bit ptr
        
        // length = len (32-bit at offset 8)
        gen.emitImm32(stencil_load_imm32, cast(int)len);
        gen.emitStoreLocal32(sliceOffset + NativeSliceLayout.LENGTH_OFFSET);  // store length
        
        // capacity = len (32-bit at offset 12)
        gen.emitImm32(stencil_load_imm32, cast(int)len);
        gen.emitStoreLocal32(sliceOffset + NativeSliceLayout.CAPACITY_OFFSET);  // store capacity
    }

    /// Initialize a slice from a string literal by storing bytes in the data section.
    private void compileStringLiteralInit(size_t sliceOffset, string strVal) {
        ubyte[] strData = cast(ubyte[])strVal.dup;
        uint len = cast(uint)strData.length;

        ubyte* dataPtr = dataSection.addData(strData);
        if (dataPtr is null) {
            throw new Exception("String literal: data section full");
        }

        // ptr = dataPtr (64-bit host pointer)
        gen.emitLoadImm64(cast(ulong)dataPtr);
        gen.emitStorePtr(sliceOffset);

        // length (32-bit at offset 8)
        gen.emitImm32(stencil_load_imm32, cast(int)len);
        gen.emitStoreLocal32(sliceOffset + NativeSliceLayout.LENGTH_OFFSET);

        // capacity (32-bit at offset 12)
        gen.emitImm32(stencil_load_imm32, cast(int)len);
        gen.emitStoreLocal32(sliceOffset + NativeSliceLayout.CAPACITY_OFFSET);
    }

    /**
     * Compile slice append: arr ~= element
     * 
     * Native slice layout: { ptr: i64, length: i32, capacity: i32 } = NativeSliceLayout.sizeof bytes
     * 
     * Algorithm (mirrors WASM emitter):
     * 1. Evaluate element, store to temp
     * 2. Check if length >= capacity
     * 3. If needs grow: alloc new buffer, copy, update ptr/capacity
     * 4. Store element at ptr[length]
     * 5. Increment length
     */
    private void compileSliceAppend(size_t sliceOffset, Expression element) {
        // Temp slots for intermediate values (use pre-allocated temp area)
        // tempSlot is at the end of the frame, with 48 bytes reserved
        size_t tempElement = tempSlot;            // element value (4 bytes)
        size_t tempNewCap = tempSlot + 4;         // new capacity (4 bytes)
        size_t tempNewPtr = tempSlot + 8;         // new buffer ptr (8 bytes, 64-bit)
        size_t tempLoopIdx = tempSlot + 16;       // copy loop index (4 bytes)
        size_t tempLoopVal = tempSlot + 20;       // temp for loaded value (4 bytes)
        
        // 1. Evaluate element value, store to temp
        compileExpression(element);
        gen.emitStoreLocal32(tempElement);
        
        // 2. Load length and capacity, compare
        gen.emitLoadLocal32(sliceOffset + NativeSliceLayout.LENGTH_OFFSET);   // x0 = length
        gen.emitMoveX0ToX1();                   // x1 = length
        gen.emitLoadLocal32(sliceOffset + NativeSliceLayout.CAPACITY_OFFSET);  // x0 = capacity
        // Now x0 = capacity, x1 = length
        // We want: if (length >= capacity) -> x0 = 1
        // Swap so we can use ge_i32 (x0 >= x1)
        gen.emit(stencil_move_arg1_to_result);  // x0 = length
        gen.emitMoveX0ToX1();                   // x1 = length (save)
        gen.emitLoadLocal32(sliceOffset + NativeSliceLayout.CAPACITY_OFFSET);  // x0 = capacity
        gen.emitMoveX0ToX2();                   // x2 = capacity
        gen.emit(stencil_move_arg1_to_result);  // x0 = length
        gen.emit(stencil_move_arg2_to_arg1);    // x1 = capacity
        // Now x0 = length, x1 = capacity, x2 = capacity
        gen.emit(stencil_ge_i32);               // x0 = (length >= capacity) ? 1 : 0
        
        // 3. Branch if no growth needed (x0 == 0)
        auto growLabel = gen.newLabel();
        auto noGrowLabel = gen.newLabel();
        auto doneGrowLabel = gen.newLabel();
        
        gen.emitBranchIfZero(noGrowLabel);      // skip grow if length < capacity
        
        // === GROW PATH ===
        gen.bindLabel(growLabel);
        
        // newCapacity = max(capacity * 2, 4)
        gen.emitLoadLocal32(sliceOffset + NativeSliceLayout.CAPACITY_OFFSET);  // x0 = capacity
        gen.emitMoveX0ToX1();                   // x1 = capacity
        gen.emit(stencil_add_i32);              // x0 = capacity * 2 (capacity + capacity)
        gen.emitStoreLocal32(tempNewCap);       // save capacity * 2
        
        // Compare with 4: if (capacity * 2 < 4) use 4
        gen.emitImm32(stencil_load_imm32, 4);
        gen.emitMoveX0ToX1();                   // x1 = 4
        gen.emitLoadLocal32(tempNewCap);        // x0 = capacity * 2
        gen.emit(stencil_lt_i32);               // x0 = (capacity * 2 < 4) ? 1 : 0
        
        auto useMinCapLabel = gen.newLabel();
        auto calcAllocLabel = gen.newLabel();
        
        gen.emitBranchIfZero(calcAllocLabel);   // if cap*2 >= 4, use it
        
        // Use minimum capacity of 4
        gen.emitImm32(stencil_load_imm32, 4);
        gen.emitStoreLocal32(tempNewCap);
        
        gen.bindLabel(calcAllocLabel);
        
        // Allocate new buffer: __ctfe_alloc(newCapacity * 4)
        gen.emitLoadLocal32(tempNewCap);        // x0 = newCapacity
        gen.emitImm32(stencil_load_imm32, 4);
        gen.emitMoveX0ToX1();                   // x1 = 4
        gen.emitLoadLocal32(tempNewCap);        // x0 = newCapacity
        gen.emit(stencil_mul_i32);              // x0 = newCapacity * 4 (bytes)
        
        // Call __ctfe_alloc(size) - size is in x0, will be shifted to x1
        ulong allocSlot = hostFunctions.getFunctionSlotAddress("__ctfe_alloc");
        ulong contextSlot = hostFunctions.getContextSlotAddress();
        gen.emitHostCall(allocSlot, contextSlot);  // x0 = new buffer ptr
        gen.emitStorePtr(tempNewPtr);         // save new ptr (64-bit)
        
        // Copy loop: for i = 0 to length: newPtr[i] = oldPtr[i]
        gen.emitImm32(stencil_load_imm32, 0);
        gen.emitStoreLocal32(tempLoopIdx);      // i = 0
        
        auto copyLoopStart = gen.newLabel();
        auto copyLoopEnd = gen.newLabel();
        
        gen.bindLabel(copyLoopStart);
        
        // Check: if (i >= length) break
        gen.emitLoadLocal32(tempLoopIdx);       // x0 = i
        gen.emitMoveX0ToX1();                   // x1 = i
        gen.emitLoadLocal32(sliceOffset + NativeSliceLayout.LENGTH_OFFSET);   // x0 = length
        gen.emitMoveX0ToX2();                   // x2 = length
        gen.emit(stencil_move_arg1_to_result);  // x0 = i
        gen.emit(stencil_move_arg2_to_arg1);    // x1 = length
        gen.emit(stencil_ge_i32);               // x0 = (i >= length)
        gen.emitBranchIfNonZero(copyLoopEnd);   // break if done
        
        // Load from old: oldPtr[i]
        gen.emitLoadPtr(sliceOffset);         // x0 = oldPtr (64-bit)
        gen.emitMoveX0ToX1();                   // x1 = oldPtr
        gen.emitLoadLocal32(tempLoopIdx);       // x0 = i
        gen.emitImm32(stencil_load_imm32, 4);
        gen.emitMoveX0ToX2();                   // x2 = 4
        gen.emitLoadLocal32(tempLoopIdx);       // x0 = i
        gen.emit(stencil_move_arg2_to_arg1);    // x1 = 4
        gen.emit(stencil_mul_i32);              // x0 = i * 4
        gen.emitMoveX0ToX1();                   // x1 = i * 4
        gen.emitLoadPtr(sliceOffset);         // x0 = oldPtr
        gen.emit(stencil_add_i64);              // x0 = oldPtr + i*4 (64-bit ptr)
        gen.emit(stencil_load_i32);             // x0 = oldPtr[i]
        gen.emitStoreLocal32(tempLoopVal);  // save loaded value
        
        // Store to new: newPtr[i] = value
        gen.emitLoadPtr(tempNewPtr);          // x0 = newPtr
        gen.emitMoveX0ToX1();                   // x1 = newPtr
        gen.emitLoadLocal32(tempLoopIdx);       // x0 = i
        gen.emitImm32(stencil_load_imm32, 4);
        gen.emitMoveX0ToX2();                   // x2 = 4
        gen.emitLoadLocal32(tempLoopIdx);       // x0 = i
        gen.emit(stencil_move_arg2_to_arg1);    // x1 = 4
        gen.emit(stencil_mul_i32);              // x0 = i * 4
        gen.emitMoveX0ToX1();                   // x1 = i * 4
        gen.emitLoadPtr(tempNewPtr);          // x0 = newPtr
        gen.emit(stencil_add_i64);              // x0 = newPtr + i*4 (64-bit ptr)
        gen.emitMoveX0ToX1();                   // x1 = dest addr
        gen.emitLoadLocal32(tempLoopVal);   // x0 = value to store
        gen.emitMoveX0ToX2();                   // x2 = value
        gen.emit(stencil_move_arg1_to_result);  // x0 = dest addr
        gen.emit(stencil_move_arg2_to_arg1);    // x1 = value
        gen.emit(stencil_store_i32);            // *dest = value
        
        // i++ (compound stencil)
        gen.emitIncLocal32(tempLoopIdx);
        
        gen.emitBranch(copyLoopStart);
        gen.bindLabel(copyLoopEnd);
        
        // Update slice ptr = newPtr
        gen.emitLoadPtr(tempNewPtr);
        gen.emitStorePtr(sliceOffset);
        
        // Update slice capacity = newCapacity
        gen.emitLoadLocal32(tempNewCap);
        gen.emitStoreLocal32(sliceOffset + NativeSliceLayout.CAPACITY_OFFSET);
        
        gen.emitBranch(doneGrowLabel);
        
        // === NO GROW PATH ===
        gen.bindLabel(noGrowLabel);
        
        gen.bindLabel(doneGrowLabel);
        
        // 4. Store element at ptr[length]
        // Calculate address: ptr + length * 4
        gen.emitLoadPtr(sliceOffset);         // x0 = ptr (64-bit)
        gen.emitMoveX0ToX1();                   // x1 = ptr
        gen.emitLoadLocal32(sliceOffset + NativeSliceLayout.LENGTH_OFFSET);   // x0 = length
        gen.emitImm32(stencil_load_imm32, 4);
        gen.emitMoveX0ToX2();                   // x2 = 4
        gen.emitLoadLocal32(sliceOffset + NativeSliceLayout.LENGTH_OFFSET);   // x0 = length
        gen.emit(stencil_move_arg2_to_arg1);    // x1 = 4
        gen.emit(stencil_mul_i32);              // x0 = length * 4
        gen.emitMoveX0ToX1();                   // x1 = length * 4
        gen.emitLoadPtr(sliceOffset);         // x0 = ptr
        gen.emit(stencil_add_i64);              // x0 = ptr + length*4 (64-bit ptr)
        gen.emitMoveX0ToX1();                   // x1 = dest addr
        gen.emitLoadLocal32(tempElement);       // x0 = element value
        gen.emitMoveX0ToX2();                   // x2 = element
        gen.emit(stencil_move_arg1_to_result);  // x0 = dest addr
        gen.emit(stencil_move_arg2_to_arg1);    // x1 = element
        gen.emit(stencil_store_i32);            // ptr[length] = element
        
        // 5. Increment length
        gen.emitLoadLocal32(sliceOffset + NativeSliceLayout.LENGTH_OFFSET);   // x0 = length
        gen.emitMoveX0ToX1();                   // x1 = length
        gen.emitImm32(stencil_load_imm32, 1);
        gen.emitMoveX0ToX2();                   // x2 = 1
        gen.emit(stencil_move_arg1_to_result);  // x0 = length
        gen.emit(stencil_move_arg2_to_arg1);    // x1 = 1
        gen.emit(stencil_add_i32);              // x0 = length + 1
        gen.emitStoreLocal32(sliceOffset + NativeSliceLayout.LENGTH_OFFSET);  // store new length
    }
    
    /**
     * Compile __writeln(args...) by lowering to typed host function calls.
     * Milestone 89: Native __writeln support.
     */
    /**
     * Emit a compiler intrinsic — raw opcodes, no function call.
     */
    private void compileIntrinsicCall(string name, Expression[] args) {
        if (name == "__intrinsic_shl") {
            assert(args.length == 2, "__intrinsic_shl requires 2 arguments");
            compileExpression(args[1]);
            gen.emitMoveX0ToX1();
            compileExpression(args[0]);
            gen.emit(stencil_shl_i32);
        } else if (name == "__intrinsic_shr_s") {
            assert(args.length == 2, "__intrinsic_shr_s requires 2 arguments");
            compileExpression(args[1]);
            gen.emitMoveX0ToX1();
            compileExpression(args[0]);
            gen.emit(stencil_shr_i32);
        } else if (name == "__intrinsic_shr_u") {
            assert(args.length == 2, "__intrinsic_shr_u requires 2 arguments");
            compileExpression(args[1]);
            gen.emitMoveX0ToX1();
            compileExpression(args[0]);
            gen.emit(stencil_lsr_i32);  // unsigned (logical) shift right
        } else if (name == "__intrinsic_unreachable") {
            // BRK #1 — triggers SIGTRAP
            gen.emitRaw32(0xD4200020);
        } else {
            throw new Exception("Unknown intrinsic: " ~ name);
        }
    }

    private void compileWriteln(Expression[] args) {
        import std.variant : Variant;
        
        foreach (arg; args) {
            // Determine argument type and emit appropriate write call
            if (auto literal = cast(LiteralExpression)arg) {
                if (literal.value.type == typeid(string)) {
                    // String literal: store in data section, call __ctfe_write_str(ptr, len)
                    string strVal = literal.value.get!string();
                    ubyte* strPtr = dataSection.addString(strVal);
                    if (strPtr is null) {
                        throw new Exception("__writeln: data section full");
                    }
                    
                    // Load ptr into x0
                    gen.emitLoadImm64(cast(ulong)strPtr);
                    // Load len into x1
                    gen.emitMoveX0ToX1();  // Save ptr to x1 temporarily
                    gen.emitImm32(stencil_load_imm32, cast(int)strVal.length);
                    // Swap: x0=len, x1=ptr -> need x0=ptr, x1=len
                    gen.emitMoveX0ToX2();  // x2 = len
                    gen.emitMoveX1ToX0();  // x0 = ptr (restore)
                    gen.emitMoveX2ToX1();  // x1 = len
                    
                    // Call __ctfe_write_str (args in x0=ptr, x1=len)
                    ulong slot = hostFunctions.getFunctionSlotAddress("__ctfe_write_str");
                    ulong ctxSlot = hostFunctions.getContextSlotAddress();
                    gen.emitHostCall(slot, ctxSlot);
                }
                else if (literal.value.type == typeid(long) || literal.value.type == typeid(int)) {
                    // Integer literal: call __ctfe_write_i32(value)
                    long val = literal.value.type == typeid(long) 
                        ? literal.value.get!long() 
                        : literal.value.get!int();
                    gen.emitImm32(stencil_load_imm32, cast(int)val);
                    
                    ulong slot = hostFunctions.getFunctionSlotAddress("__ctfe_write_i32");
                    ulong ctxSlot = hostFunctions.getContextSlotAddress();
                    gen.emitHostCall(slot, ctxSlot);
                }
                else if (literal.value.type == typeid(bool)) {
                    // Boolean literal: call __ctfe_write_bool(0 or 1)
                    bool val = literal.value.get!bool();
                    gen.emitImm32(stencil_load_imm32, val ? 1 : 0);
                    
                    ulong slot = hostFunctions.getFunctionSlotAddress("__ctfe_write_bool");
                    ulong ctxSlot = hostFunctions.getContextSlotAddress();
                    gen.emitHostCall(slot, ctxSlot);
                }
            }
            else {
                // Non-literal expression: evaluate and print as i32
                compileExpression(arg);
                
                ulong slot = hostFunctions.getFunctionSlotAddress("__ctfe_write_i32");
                ulong ctxSlot = hostFunctions.getContextSlotAddress();
                gen.emitHostCall(slot, ctxSlot);
            }
        }
        
        // Emit newline at the end
        ulong newlineSlot = hostFunctions.getFunctionSlotAddress("__ctfe_write_newline");
        ulong ctxSlot = hostFunctions.getContextSlotAddress();
        gen.emitHostCall(newlineSlot, ctxSlot);
    }
    
    /**
     * Check if an expression contains a function call (for register clobber detection)
     */
    private bool containsCall(Expression expr) {
        if (cast(CallExpression)expr) return true;
        
        if (auto binOp = cast(BinaryExpression)expr) {
            return containsCall(binOp.left) || containsCall(binOp.right);
        }
        if (auto unaryOp = cast(UnaryExpression)expr) {
            return containsCall(unaryOp.operand);
        }
        if (auto indexExpr = cast(IndexExpression)expr) {
            return containsCall(indexExpr.array) || containsCall(indexExpr.index);
        }
        if (auto memberExpr = cast(MemberExpression)expr) {
            return containsCall(memberExpr.object);
        }
        if (auto castExpr = cast(CastExpression)expr) {
            return containsCall(castExpr.expression);
        }
        return false;
    }
    
    /**
     * Compile struct field assignment: obj.field = value
     */
    private void compileMemberAssignment(MemberExpression member, AssignmentExpression assign) {
        auto structDecl = getStructDeclFromExpr(member.object);
        if (structDecl is null)
            throw new NativeCompileError("Cannot determine struct type for member assignment", assign.location);

        auto field = structDecl.getField(member.memberName);
        if (field is null)
            throw new NativeCompileError("Unknown field: " ~ member.memberName, assign.location);

        // Local struct variable: direct store at known offset
        if (auto ident = cast(IdentifierExpression)member.object) {
            if (auto varInfo = ident.name in localVars) {
                compileExpression(assign.right);
                gen.emitStoreLocal32(varInfo.offset + field.offset);
                return;
            }
        }

        // Pointer-based target (nested access, index, etc.)
        compileExpression(assign.right);
        gen.emitMoveX0ToX9();
        compileExpression(member.object);
        gen.emitStoreToPointerFromX9(field.offset);
    }

    /**
     * Get the StructDecl from an expression (for member access type resolution)
     */
    private StructDecl getStructDeclFromExpr(Expression expr) {
        // For identifier expressions, check our local struct types first
        if (auto ident = cast(IdentifierExpression)expr) {
            // Check local variables
            if (auto info = ident.name in localVars) {
                if (info.isStruct) return info.structDecl;
            }
            // Fall back to symbol table
            auto symbol = symbolTable.lookupSymbol(ident.name);
            if (symbol) {
                return symbol.type.asStruct();
            }
        }
        // For member expressions (nested struct access like o.inner),
        // get the struct type of the field
        if (auto member = cast(MemberExpression)expr) {
            // First get the struct decl of the base object
            auto baseDecl = getStructDeclFromExpr(member.object);
            if (baseDecl !is null) {
                // Find the field and check if it's a struct type
                auto field = baseDecl.getField(member.memberName);
                if (field !is null) {
                    return field.type.asStruct();
                }
            }
        }
        // For index expressions (array element access), get element struct type
        if (auto indexExpr = cast(IndexExpression)expr) {
            if (auto ident = cast(IdentifierExpression)indexExpr.array) {
                if (auto info = ident.name in localVars) {
                    if (info.elementType)
                        return info.elementType.asStruct();
                }
            }
        }
        // For call expressions (struct construction), get the struct type
        if (auto call = cast(CallExpression)expr) {
            if (auto funcIdent = cast(IdentifierExpression)call.function_) {
                auto symbol = symbolTable.lookupSymbol(funcIdent.name);
                if (symbol && symbol.kind == SymbolKind.Type) {
                    return symbol.type.asStruct();
                }
            }
        }
        return null;
    }

    override ExecutionResult call(long[] args) {
        import codegen.native.codegen_interface : setjmp;

        // Set up execution context for host functions
        NativeCTFEContext ctx;
        ctx.dataSection = &dataSection;
        ctx.errorKind = CTFEErrorKind.None;
        hostFunctions.setContext(&ctx);
        scope(exit) hostFunctions.setContext(null);

        // Set up error recovery point - longjmp returns here on trap
        if (setjmp(ctx.errorJump) != 0) {
            // Got here via longjmp - error occurred
            return ExecutionResult.failure(ctfeErrorMessageWithStack(&ctx));
        }

        // Prepend arena (0) if entry function needs it (native uses __ctfe_alloc, not arena)
        long[] fullArgs;
        if (entryNeedsArena) fullArgs ~= 0L;
        fullArgs ~= args;

        // Call the compiled function with appropriate number of arguments
        // ARM64 calling convention: first 8 args in x0-x7
        long result;

        switch (fullArgs.length) {
            case 0:
                alias Fn0 = extern(C) long function();
                result = (cast(Fn0)(gen.base + entryPoint))();
                break;
            case 1:
                alias Fn1 = extern(C) long function(long);
                result = (cast(Fn1)(gen.base + entryPoint))(fullArgs[0]);
                break;
            case 2:
                alias Fn2 = extern(C) long function(long, long);
                result = (cast(Fn2)(gen.base + entryPoint))(fullArgs[0], fullArgs[1]);
                break;
            case 3:
                alias Fn3 = extern(C) long function(long, long, long);
                result = (cast(Fn3)(gen.base + entryPoint))(fullArgs[0], fullArgs[1], fullArgs[2]);
                break;
            case 4:
                alias Fn4 = extern(C) long function(long, long, long, long);
                result = (cast(Fn4)(gen.base + entryPoint))(fullArgs[0], fullArgs[1], fullArgs[2], fullArgs[3]);
                break;
            default:
                throw new Exception("Native backend: too many parameters (max 4 for now)");
        }

        return ExecutionResult.fromInt(cast(int)result);  // Sign-extend 32-bit to 64-bit
    }
    
    override ExecutionResult callByName(string targetFuncName, long[] args) {
        import codegen.native.codegen_interface : setjmp;

        // Set up execution context for host functions
        NativeCTFEContext ctx;
        ctx.dataSection = &dataSection;
        ctx.errorKind = CTFEErrorKind.None;
        hostFunctions.setContext(&ctx);
        scope(exit) hostFunctions.setContext(null);

        // Look up function entry point and param count
        auto labelPtr = targetFuncName in functionLabels;
        if (labelPtr is null) {
            return ExecutionResult.failure("Function not found: " ~ targetFuncName);
        }

        auto funcDeclPtr = targetFuncName in functionDecls;
        if (funcDeclPtr is null) {
            return ExecutionResult.failure("Function decl not found: " ~ targetFuncName);
        }

        size_t targetEntry = (*labelPtr).offset;
        bool needsArena = (*funcDeclPtr).needsArena;

        // Set up error recovery point - longjmp returns here on trap
        if (setjmp(ctx.errorJump) != 0) {
            // Got here via longjmp - error occurred
            return ExecutionResult.failure(ctfeErrorMessageWithStack(&ctx));
        }

        // Prepend arena (0) if target function needs it
        long[] fullArgs;
        if (needsArena) fullArgs ~= 0L;
        fullArgs ~= args;

        // Call with the target function's entry point
        long result;
        switch (fullArgs.length) {
            case 0:
                alias Fn0 = extern(C) long function();
                result = (cast(Fn0)(gen.base + targetEntry))();
                break;
            case 1:
                alias Fn1 = extern(C) long function(long);
                result = (cast(Fn1)(gen.base + targetEntry))(fullArgs[0]);
                break;
            case 2:
                alias Fn2 = extern(C) long function(long, long);
                result = (cast(Fn2)(gen.base + targetEntry))(fullArgs[0], fullArgs[1]);
                break;
            case 3:
                alias Fn3 = extern(C) long function(long, long, long);
                result = (cast(Fn3)(gen.base + targetEntry))(fullArgs[0], fullArgs[1], fullArgs[2]);
                break;
            case 4:
                alias Fn4 = extern(C) long function(long, long, long, long);
                result = (cast(Fn4)(gen.base + targetEntry))(fullArgs[0], fullArgs[1], fullArgs[2], fullArgs[3]);
                break;
            default:
                return ExecutionResult.failure("Too many parameters (max 4)");
        }

        return ExecutionResult.fromInt(cast(int)result);  // Sign-extend 32-bit to 64-bit
    }
    
    override ExecutionResult callWithLargeReturn(string targetFuncName, long[] args, uint resultSize) {
        import codegen.native.codegen_interface : setjmp;
        import core.stdc.stdlib : malloc, free;

        // Allocate buffer for result
        ubyte* resultBuf = cast(ubyte*)malloc(resultSize);
        if (resultBuf is null) {
            return ExecutionResult.failure("Failed to allocate result buffer");
        }
        scope(exit) free(resultBuf);

        // Set up execution context for host functions
        NativeCTFEContext ctx;
        ctx.dataSection = &dataSection;
        ctx.errorKind = CTFEErrorKind.None;
        hostFunctions.setContext(&ctx);
        scope(exit) hostFunctions.setContext(null);

        // Look up function entry point
        auto labelPtr = targetFuncName in functionLabels;
        if (labelPtr is null) {
            return ExecutionResult.failure("Function not found: " ~ targetFuncName);
        }

        // Check if target needs arena
        bool needsArena = false;
        if (auto funcDeclPtr = targetFuncName in functionDecls) {
            needsArena = (*funcDeclPtr).needsArena;
        }

        size_t targetEntry = (*labelPtr).offset;

        // Set up error recovery point
        if (setjmp(ctx.errorJump) != 0) {
            return ExecutionResult.failure(ctfeErrorMessageWithStack(&ctx));
        }

        // Prepend result pointer, then arena (0) if needed, then user args
        long[] fullArgs;
        fullArgs ~= cast(long)resultBuf;
        if (needsArena) fullArgs ~= 0L;
        fullArgs ~= args;

        // Call function (void return, writes to resultBuf)
        switch (fullArgs.length) {
            case 1:
                alias Fn1 = extern(C) void function(long);
                (cast(Fn1)(gen.base + targetEntry))(fullArgs[0]);
                break;
            case 2:
                alias Fn2 = extern(C) void function(long, long);
                (cast(Fn2)(gen.base + targetEntry))(fullArgs[0], fullArgs[1]);
                break;
            case 3:
                alias Fn3 = extern(C) void function(long, long, long);
                (cast(Fn3)(gen.base + targetEntry))(fullArgs[0], fullArgs[1], fullArgs[2]);
                break;
            case 4:
                alias Fn4 = extern(C) void function(long, long, long, long);
                (cast(Fn4)(gen.base + targetEntry))(fullArgs[0], fullArgs[1], fullArgs[2], fullArgs[3]);
                break;
            default:
                return ExecutionResult.failure("Too many parameters (max 4)");
        }

        // Copy result bytes
        ubyte[] resultBytes = resultBuf[0 .. resultSize].dup;

        return ExecutionResult.fromArray(resultBytes);
    }
    
    override ubyte[] readMemory(uint offset, uint length) {
        auto ptr = cast(ubyte*)cast(size_t)offset;
        return ptr[0 .. length].dup;
    }

    override bool hasFunction(string targetFuncName) {
        return (targetFuncName in functionLabels) !is null;
    }

    override void dispose() {
        if (gen.base) {
            gen.free();
        }
        if (dataSection.base) {
            dataSection.free();
        }
    }
    
    override string name() { return funcName; }
}

/**
 * WASM Backend - wraps the existing BinaryEmitter and CTFERuntime
 */
