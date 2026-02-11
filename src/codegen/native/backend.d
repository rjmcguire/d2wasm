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

class NativeBackend : Backend {
    private SymbolTable symbolTable;
    private string lastError;
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
            return new NativeCompiledFunction(funcs, entryFuncName, symbolTable, enableStackTrace);
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
    // Additional imports for this class
    import semantic.symbol_table : SymbolKind;
    
    private string funcName;
    private NativeCodeGen gen;  // renamed from codegen to avoid module name collision
    private size_t entryPoint;
    private size_t paramCount;           // number of function parameters
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
        uint offset;              // Stack offset
        StructDecl structDecl;    // Non-null when kind == struct_
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
    private uint nextLocalOffset;
    private uint totalLocalBytes;
    private uint tempSlot;               // stack offset for expression temporaries
    private uint tempSlotDepth;          // nesting depth for temp slot usage
    
    // Large return tracking (hidden result pointer pattern)
    private bool currentFunctionHasHiddenResult;
    private uint currentFunctionResultPtrOffset;
    private StructDecl currentFunctionReturnStructDecl;
    private uint currentFunctionReturnArrayBytes;  // >0 for static array returns

    // Method tracking (hidden 'this' parameter)
    private StructDecl currentMethodStruct;  // non-null when compiling a method
    private uint currentThisOffset;          // stack offset of 'this' pointer
    
    // For return statements to jump to
    private Label epilogueLabel;
    
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
            string name = mangledName(func);
            functionDecls[name] = func;
        }

        // Create labels for all functions before compiling any
        foreach (func; funcs) {
            string name = mangledName(func);
            functionLabels[name] = gen.newLabel();
        }
        
        // Find entry function and store its param count
        if (auto entryFunc = entryFuncName in functionDecls) {
            this.paramCount = (*entryFunc).parameters.length;
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

    /// Get the mangled name for a function (StructName_methodName for methods).
    private static string mangledName(FunctionDecl func) {
        if (func.isMethod && func.parent !is null) {
            if (auto sd = cast(StructDecl)func.parent)
                return sd.name ~ "_" ~ func.name;
            if (auto cd = cast(ClassDecl)func.parent)
                return cd.name ~ "_" ~ func.name;
        }
        return func.name;
    }

    private void compileFunction(FunctionDecl func) {
        import std.stdio : writeln;

        string name = mangledName(func);

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
        uint resultPtrOffset = 0;
        StructDecl returnStructDecl = null;
        uint returnArrayBytes = 0;
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

        // Reserve space for parameters (x0/x1/x2... depending on hidden ptr)
        foreach (param; func.parameters) {
            NativeLocalInfo nli;
            nli.offset = nextLocalOffset;

            uint paramSize = 4;  // default for scalar (int, bool, etc.)
            if (auto userType = cast(UserType)param.type) {
                userType.ensureResolved(symbolTable);
                if (auto structDecl = userType.asStruct()) {
                    assert(structDecl.structSize > 0,
                        "StructDecl '" ~ structDecl.name ~ "' has zero size - layout not computed");
                    nli.kind = VarKind.struct_;
                    nli.structDecl = structDecl;
                    paramSize = cast(uint)structDecl.structSize;
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
        uint bodyLocalBytes = countLocalBytesInStatement(func.body_);
        
        // Reserve extra space for expression temporaries
        // Need 40 bytes for slice append temps: element(4) + newCap(4) + newPtr(8) + loopIdx(4) + loopVal(4) + padding
        // Plus space for struct construction temps (at tempSlot + 16 onwards)
        uint tempSlotOffset = nextLocalOffset + bodyLocalBytes;
        tempSlot = tempSlotOffset;  // Store for use in compileExpression
        uint totalNeeded = tempSlotOffset + 64;  // 64 bytes for temps (struct construction + slice append)
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
            gen.emitStoreLocal(currentFunctionResultPtrOffset);  // Save x0 (64-bit ptr)
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
            gen.emitStoreLocal(currentThisOffset);  // Save 64-bit pointer
        }

        // Spill parameters from registers to stack
        // ARM64 calling convention: first 8 args in x0-x7
        // If hidden result ptr, params are shifted: x1, x2, x3... instead of x0, x1, x2...
        int regOffset = (currentFunctionHasHiddenResult ? 1 : 0) + (currentMethodStruct !is null ? 1 : 0);
        foreach (i, param; func.parameters) {
            int regIdx = cast(int)i + regOffset;
            if (regIdx >= 4) {
                throw new Exception("Native backend: more than 4 parameters not yet supported");
            }
            // Store parameter register to its stack slot
            auto nli = param.name in localVars;
            assert(nli !is null, "Parameter '" ~ param.name ~ "' not in localVars");
            uint offset = nli.offset;

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
                    uint structSize = cast(uint)nli.structDecl.structSize;
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
                    for (uint off = 0; off < NativeSliceLayout.sizeof; off += 4) {
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
                userType.ensureResolved(symbolTable);
                if (auto sd = userType.asStruct()) {
                    assert(sd.structSize > 0, "StructDecl has zero size");
                    bytes = cast(uint)sd.structSize;
                } else {
                    bytes = 4;
                }
            } else if (auto arrType = cast(ArrayType)varDecl.type) {
                if (arrType.arraySize is null) {
                    // Slice struct + data
                    bytes = NativeSliceLayout.sizeof;
                    // Add data size if initialized with literal
                    if (auto arrLit = cast(ArrayLiteralExpression)varDecl.initializer) {
                        bytes += cast(uint)(arrLit.elements.length * 4);
                    }
                } else {
                    // Static array: inline storage for N elements
                    // arraySize is a LiteralExpression with the size
                    auto sizeLit = cast(LiteralExpression)arrType.arraySize;
                    assert(sizeLit !is null, "Static array size is not a LiteralExpression");
                    assert(sizeLit.value.type == typeid(long), "Static array size literal is not a long");
                    uint length = cast(uint)sizeLit.value.get!long();
                    bytes = length * 4;  // 4 bytes per element
                }
            } else {
                bytes = 4;  // int, bool, etc.
            }
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            bytes += countLocalBytesInStatement(ifStmt.thenStatement);
            bytes += countLocalBytesInStatement(ifStmt.elseStatement);
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            bytes += countLocalBytesInStatement(whileStmt.body_);
        } else if (auto forStmt = cast(ForStatement)stmt) {
            bytes += countLocalBytesInStatement(forStmt.init);
            bytes += countLocalBytesInStatement(forStmt.body_);
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
                if (currentFunctionHasHiddenResult && currentFunctionReturnStructDecl !is null) {
                    // Struct return: copy result to hidden result pointer
                    assert(currentFunctionReturnStructDecl.structSize > 0,
                        "Struct return with zero-size struct");
                    assert(tempSlot + 8 + 8 <= totalLocalBytes,
                        "srcTempSlot overflows frame");
                    // First compile the expression once to get source address
                    compileExpression(ret.value);  // x0 = address of result struct

                    // Save source pointer to a temp slot
                    uint srcTempSlot = tempSlot + 8;  // Use temp slot area
                    gen.emitStoreLocal(srcTempSlot);  // Save 64-bit ptr

                    // Copy struct data word by word
                    uint structSize = cast(uint)currentFunctionReturnStructDecl.structSize;
                    for (uint off = 0; off < structSize; off += 4) {
                        // Load from source
                        gen.emitLoadLocal(srcTempSlot);      // x0 = src ptr
                        gen.emitLoadFromPointer(off);        // x0 = *(src + off)
                        gen.emitMoveX0ToX9();                // x9 = value

                        // Store to dest
                        gen.emitLoadLocal(currentFunctionResultPtrOffset);  // x0 = dest ptr
                        gen.emitStoreToPointerFromX9(off);   // *(dest + off) = x9
                    }
                } else if (currentFunctionHasHiddenResult && currentFunctionReturnArrayBytes > 0) {
                    // Static array return: copy array data to hidden result pointer
                    assert(tempSlot + 8 + 8 <= totalLocalBytes,
                        "srcTempSlot overflows frame");
                    compileExpression(ret.value);  // x0 = address of source array

                    uint srcTempSlot = tempSlot + 8;
                    gen.emitStoreLocal(srcTempSlot);  // Save 64-bit ptr

                    for (uint off = 0; off < currentFunctionReturnArrayBytes; off += 4) {
                        gen.emitLoadLocal(srcTempSlot);      // x0 = src ptr
                        gen.emitLoadFromPointer(off);        // x0 = *(src + off)
                        gen.emitMoveX0ToX9();                // x9 = value

                        gen.emitLoadLocal(currentFunctionResultPtrOffset);  // x0 = dest ptr
                        gen.emitStoreToPointerFromX9(off);   // *(dest + off) = x9
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
            uint varSize = 4;  // default to 4 bytes for int
            
            if (auto userType = cast(UserType)varDecl.type) {
                userType.ensureResolved(symbolTable);
                if (auto sd = userType.asStruct()) {
                    assert(sd.structSize > 0,
                        "StructDecl '" ~ sd.name ~ "' has zero size - layout not computed");
                    structType = sd;
                    varSize = cast(uint)sd.structSize;
                }
            } else if (auto arrType = cast(ArrayType)varDecl.type) {
                if (arrType.arraySize is null) {
                    // Dynamic array (slice) = NativeSliceLayout.sizeof bytes on native (64-bit ptr)
                    isSlice = true;
                    varSize = NativeSliceLayout.sizeof;
                    // Add data size if initialized with literal
                    if (auto arrLit = cast(ArrayLiteralExpression)varDecl.initializer) {
                        varSize += cast(uint)(arrLit.elements.length * 4);
                    }
                } else {
                    // Static array: inline storage for N elements
                    auto sizeLit = cast(LiteralExpression)arrType.arraySize;
                    assert(sizeLit !is null, "Static array size is not a LiteralExpression");
                    assert(sizeLit.value.type == typeid(long), "Static array size literal is not a long");
                    uint length = cast(uint)sizeLit.value.get!long();
                    varSize = length * 4;  // 4 bytes per element
                    staticArrayLength = length;
                }
            }
            
            // Allocate stack slot for this variable
            NativeLocalInfo nli;
            nli.offset = nextLocalOffset;
            if (structType) {
                nli.kind = VarKind.struct_;
                nli.structDecl = structType;
            } else if (isSlice) {
                nli.kind = VarKind.slice;
                if (auto at = cast(ArrayType)varDecl.type) {
                    nli.sliceElemSize = cast(uint)at.elementType.size();
                    if (nli.sliceElemSize == 0) nli.sliceElemSize = 4;
                } else {
                    nli.sliceElemSize = 4;
                }
            } else if (staticArrayLength > 0) {
                nli.kind = VarKind.staticArray;
                nli.staticArraySize = staticArrayLength;
                nli.staticArrayElemSize = 4;
            }
            // else: kind stays VarKind.scalar (default)
            localVars[varDecl.name] = nli;
            
            // Compile initializer if present
            if (varDecl.initializer) {
                if (nli.isStruct) {
                    // Struct initialization
                    if (auto call = cast(CallExpression)varDecl.initializer) {
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
                                            uint fieldOffset = nextLocalOffset + cast(uint)field.offset;
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
                                // ARM64: x0 = result ptr, x1..xN = actual args
                                assert((funcIdent.name in functionLabels) !is null,
                                    "Struct return call to '" ~ funcIdent.name ~
                                    "' but no function label exists");

                                // First, compile and save all arguments to temp slots
                                uint tempOffset = nextLocalOffset + varSize;
                                uint[] argTemps;
                                foreach (arg; call.arguments) {
                                    compileExpression(arg);
                                    gen.emitStoreLocal32(tempOffset);
                                    argTemps ~= tempOffset;
                                    tempOffset += 4;
                                }
                                
                                // Load args into registers in reverse order (x3, x2, x1)
                                // to avoid clobbering
                                if (argTemps.length > 2) {
                                    gen.emitLoadLocal32(argTemps[2]);
                                    gen.emitMoveX0ToX3();
                                }
                                if (argTemps.length > 1) {
                                    gen.emitLoadLocal32(argTemps[1]);
                                    gen.emitMoveX0ToX2();
                                }
                                if (argTemps.length > 0) {
                                    gen.emitLoadLocal32(argTemps[0]);
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
                    } else {
                        throw new Exception("Slice can only be initialized from array literal, string literal, or import()");
                    }
                } else if (nli.isStaticArray) {
                    // Static array initialization from array literal
                    if (auto arrLit = cast(ArrayLiteralExpression)varDecl.initializer) {
                        // Store each element directly on stack
                        foreach (i, elem; arrLit.elements) {
                            compileExpression(elem);
                            gen.emitStoreLocal32(nextLocalOffset + cast(uint)(i * 4));
                        }
                    } else if (auto call = cast(CallExpression)varDecl.initializer) {
                        // Function call returning static array — hidden result pointer
                        if (auto funcIdent = cast(IdentifierExpression)call.function_) {
                            auto funcLabelPtr = funcIdent.name in functionLabels;
                            if (funcLabelPtr is null)
                                throw new Exception("Function not compiled: " ~ funcIdent.name);

                            // Compile and save all arguments to temp slots
                            uint tempOffset = nextLocalOffset + varSize;
                            uint[] argTemps;
                            foreach (arg; call.arguments) {
                                compileExpression(arg);
                                gen.emitStoreLocal32(tempOffset);
                                argTemps ~= tempOffset;
                                tempOffset += 4;
                            }

                            // Load args into registers in reverse order
                            if (argTemps.length > 2) {
                                gen.emitLoadLocal32(argTemps[2]);
                                gen.emitMoveX0ToX3();
                            }
                            if (argTemps.length > 1) {
                                gen.emitLoadLocal32(argTemps[1]);
                                gen.emitMoveX0ToX2();
                            }
                            if (argTemps.length > 0) {
                                gen.emitLoadLocal32(argTemps[0]);
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
        } else if (auto forStmt = cast(ForStatement)stmt) {
            // Compile: for (init; cond; update) { body }
            auto loopStart = gen.newLabel();
            auto loopEnd = gen.newLabel();
            
            // Compile init (if present)
            if (forStmt.init) {
                compileStatement(forStmt.init);
            }
            
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
            
            // Compile update (if present)
            if (forStmt.update) {
                compileExpression(forStmt.update);
            }
            
            // Jump back to start
            gen.emitBranch(loopStart);
            
            // Loop end
            gen.bindLabel(loopEnd);
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
            } else {
                throw new Exception("Literal type not supported: " ~ lit.value.type.toString());
            }
        } else if (auto binOp = cast(BinaryExpression)expr) {
            // Check if left operand might clobber x1 (function call, nested binary expr, or index expr)
            // IndexExpression uses x1 internally for address calculation
            bool leftMightClobber = containsFunctionCall(binOp.left) || 
                                    cast(BinaryExpression)binOp.left !is null ||
                                    cast(IndexExpression)binOp.left !is null;
            
            // Compile right operand first (into x0)
            compileExpression(binOp.right);
            
            if (leftMightClobber) {
                // Save right result to temp slot (function calls clobber x0-x7)
                // Use depth-aware temp slot to handle nested expressions
                uint myTempSlot = tempSlot + (tempSlotDepth * 4);
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
                    gen.emit(stencil_shl_i32);
                    break;
                case BinaryExpression.Operator.ShiftRight:
                    gen.emit(stencil_shr_i32);
                    break;
                case BinaryExpression.Operator.UnsignedShiftRight:
                    // TODO: implement unsigned shift (for now use signed)
                    gen.emit(stencil_shr_i32);
                    break;
                case BinaryExpression.Operator.LogicalAnd:
                    gen.emit(stencil_logical_and_i32);
                    break;
                case BinaryExpression.Operator.LogicalOr:
                    gen.emit(stencil_logical_or_i32);
                    break;
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
                    gen.emitLoadLocal(currentThisOffset);  // x0 = this ptr (64-bit)
                    gen.emitLoadFromPointer(cast(uint)field.offset);  // x0 = this.field
                    return;
                }
                throw new Exception("Unknown variable in native backend: " ~ ident.name);
            } else {
                throw new Exception("Unknown variable in native backend: " ~ ident.name);
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

            auto targetIdent = cast(IdentifierExpression)assign.left;
            if (targetIdent is null) {
                throw new Exception("Assignment to non-identifier not yet supported in native backend");
            }
            
            auto info = targetIdent.name in localVars;
            if (info is null) {
                // In a method: check for implicit field assignment
                if (currentMethodStruct !is null && assign.operator == AssignmentExpression.Operator.Assign) {
                    auto field = currentMethodStruct.getField(targetIdent.name);
                    if (field) {
                        compileExpression(assign.right);  // x0 = value
                        gen.emitMoveX0ToX9();             // x9 = value
                        gen.emitLoadLocal(currentThisOffset);  // x0 = this ptr
                        gen.emitStoreToPointerFromX9(cast(uint)field.offset);  // this.field = x9
                        return;
                    }
                }
                throw new Exception("Unknown variable in native backend: " ~ targetIdent.name);
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
            
            if (assign.operator == AssignmentExpression.Operator.Assign) {
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
                        gen.emit(stencil_shl_i32);
                        break;
                    case AssignmentExpression.Operator.ShiftRightAssign:
                        gen.emit(stencil_shr_i32);
                        break;
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
                
                // Check if this is a call to a known function
                if (auto labelPtr = funcIdent.name in functionLabels) {
                    if (call.arguments.length > 4) {
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
                        uint[] argSlots;
                        foreach (i, arg; call.arguments) {
                            compileExpression(arg);
                            uint slot = tempSlot + cast(uint)(i * 4);
                            gen.emitStoreLocal32(slot);
                            argSlots ~= slot;
                        }
                        // Load from temp slots into argument registers (reverse order!)
                        // Load x1/x2/x3 first, then x0 last (so we don't clobber x0)
                        for (long i = cast(long)argSlots.length - 1; i >= 0; i--) {
                            gen.emitLoadLocal32(argSlots[cast(size_t)i]);
                            switch (i) {
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
                            // Move x0 to target register (x0 stays, others need mov)
                            switch (i) {
                                case 0: break;  // already in x0
                                case 1: gen.emitMoveX0ToX1(); break;
                                case 2: gen.emitMoveX0ToX2(); break;
                                case 3: gen.emitMoveX0ToX3(); break;
                                default: assert(0, "argument register > 3");
                            }
                        }
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
                    uint totalOffset = varInfo.offset + cast(uint)field.offset;
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
            uint fieldOffset = cast(uint)field.offset;
            // Aggregate fields: compute address (for further nested access)
            // Scalar fields: load the value
            if (field.type.isAggregate()) {
                // Add offset to pointer: x0 = x0 + fieldOffset
                if (fieldOffset > 0) {
                    gen.emitMoveX0ToX1();
                    gen.emitImm32(stencil_load_imm32, cast(int)fieldOffset);
                    gen.emit(stencil_add_i32);
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
            gen.emitStoreLocal32(sliceOffset + NativeSliceLayout.LENGTH_OFFSET);  // store length
            
            // capacity = elemCount
            gen.emitImm32(stencil_load_imm32, cast(int)elemCount);
            gen.emitStoreLocal32(sliceOffset + NativeSliceLayout.CAPACITY_OFFSET);  // store capacity
            
            // Leave pointer to slice struct in x0
            gen.emitLoadStackPointer();
            gen.emitMoveX0ToX1();
            gen.emitImm32(stencil_load_imm32, cast(int)sliceOffset);
            gen.emit(stencil_add_i32);
            
        } else if (auto indexExpr = cast(IndexExpression)expr) {
            // Array/slice indexing: arr[i]
            if (auto ident = cast(IdentifierExpression)indexExpr.array) {
                if (auto info = ident.name in localVars) {
                    final switch (info.kind) {
                        case VarKind.staticArray:
                            // Static array: elements stored inline at offset
                            // For constant index, load directly
                            if (auto indexLit = cast(LiteralExpression)indexExpr.index) {
                                if (indexLit.value.type == typeid(long)) {
                                    uint idx = cast(uint)indexLit.value.get!long();
                                    gen.emitLoadLocal32(info.offset + idx * 4);
                                    return;
                                }
                            }
                            // For dynamic index, compute offset
                            compileExpression(indexExpr.index);
                            // x0 = index, compute index * 4
                            gen.emitMoveX0ToX1();  // x1 = index
                            gen.emitImm32(stencil_load_imm32, 4);
                            gen.emit(stencil_mul_i32);  // x0 = index * 4
                            gen.emitMoveX0ToX1();  // x1 = index * 4
                            // Get base address of array
                            gen.emitStackAddress(info.offset);  // x0 = SP + offset
                            gen.emit(stencil_add_i32);  // x0 = base + index * 4
                            // Load from computed address
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
                            gen.emitLoadLocal(info.offset);  // x0 = ptr (64-bit!)

                            // Compute address: ptr + byte offset
                            gen.emit(stencil_add_i32);

                            // Load value from computed address (byte or word)
                            if (info.elemSize == 1)
                                gen.emitLoadByteFromPointer(0);
                            else
                                gen.emitLoadFromPointer(0);
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
            if (info is null || !info.isSlice)
                throw new Exception("Can only sub-slice a slice variable in native backend");

            uint elemSize = info.elemSize;
            uint tempOffset = (nextLocalOffset + 7) & ~7;  // 8-byte align for 64-bit ptr store
            nextLocalOffset = tempOffset + cast(uint)NativeSliceLayout.sizeof;

            // Compute new ptr = source.ptr + start * elemSize
            // Load source.ptr (64-bit)
            gen.emitLoadLocal(info.offset);
            gen.emitMoveX0ToX9();  // x9 = source.ptr

            // Compute start * elemSize
            compileExpression(sliceExpr.start);
            gen.emitMoveX0ToX1();  // x1 = start
            gen.emitImm32(stencil_load_imm32, elemSize);
            gen.emit(stencil_mul_i32);  // x0 = start * elemSize

            // ptr + start * elemSize (64-bit add: x9 + x0)
            gen.emitMoveX0ToX1();  // x1 = byte offset
            gen.emitMoveX9ToX0();  // x0 = source.ptr
            gen.emit(stencil_add_i32);  // x0 = new ptr
            gen.emitStoreLocal(tempOffset);  // store 64-bit ptr

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

        final switch (info.kind) {
            case VarKind.staticArray:
                // For constant index, store directly to stack
                if (auto indexLit = cast(LiteralExpression)indexExpr.index) {
                    if (indexLit.value.type == typeid(long)) {
                        uint idx = cast(uint)indexLit.value.get!long();
                        compileExpression(value);  // x0 = value
                        gen.emitStoreLocal32(info.offset + idx * 4);
                        return;
                    }
                }
                // Dynamic index: compute value, save to x9, compute address, store
                compileExpression(value);  // x0 = value
                gen.emitMoveX0ToX9();      // x9 = value (preserved across address calc)
                compileExpression(indexExpr.index);  // x0 = index
                gen.emitMoveX0ToX1();      // x1 = index
                gen.emitImm32(stencil_load_imm32, 4);
                gen.emit(stencil_mul_i32);  // x0 = index * 4
                gen.emitMoveX0ToX1();      // x1 = byte offset
                gen.emitStackAddress(info.offset);  // x0 = base address
                gen.emit(stencil_add_i32);  // x0 = target address
                gen.emitStoreToPointerFromX9(0);    // STR w9, [x0, #0]
                return;

            case VarKind.slice:
                // Slice index assignment: load ptr, compute offset, store
                compileExpression(value);  // x0 = value
                gen.emitMoveX0ToX9();      // x9 = value
                compileExpression(indexExpr.index);  // x0 = index
                gen.emitMoveX0ToX1();      // x1 = index
                gen.emitImm32(stencil_load_imm32, 4);
                gen.emit(stencil_mul_i32);  // x0 = index * 4
                gen.emitMoveX0ToX1();      // x1 = byte offset
                gen.emitLoadLocal(info.offset);  // x0 = slice ptr (64-bit)
                gen.emit(stencil_add_i32);  // x0 = target address
                gen.emitStoreToPointerFromX9(0);    // STR w9, [x0, #0]
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
        string mangledMethodName = structDecl.name ~ "_" ~ method.name;
        auto labelPtr = mangledMethodName in functionLabels;
        if (labelPtr is null)
            throw new Exception("Method not compiled: " ~ mangledMethodName);

        if (args.length > 3)
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
            uint[] argSlots;
            foreach (i, arg; args) {
                compileExpression(arg);
                uint slot = tempSlot + cast(uint)(i * 4);
                gen.emitStoreLocal32(slot);
                argSlots ~= slot;
            }
            // Load from temp slots into x1, x2, x3 (reverse order to not clobber)
            for (long i = cast(long)argSlots.length - 1; i >= 0; i--) {
                gen.emitLoadLocal32(argSlots[cast(size_t)i]);
                switch (i) {
                    case 0: gen.emitMoveX0ToX1(); break;
                    case 1: gen.emitMoveX0ToX2(); break;
                    case 2: gen.emitMoveX0ToX3(); break;
                    default: assert(0, "method argument register > 3");
                }
            }
        } else {
            // No nested calls - direct register assignment (reverse order)
            for (long i = cast(long)args.length - 1; i >= 0; i--) {
                compileExpression(args[i]);
                switch (i) {
                    case 0: gen.emitMoveX0ToX1(); break;
                    case 1: gen.emitMoveX0ToX2(); break;
                    case 2: gen.emitMoveX0ToX3(); break;
                    default: assert(0, "method argument register > 3");
                }
            }
        }

        // Load 'this' pointer into x0 (stack address of the struct)
        gen.emitStackAddress(info.offset);

        // Emit the call
        gen.emitCall(*labelPtr);
        // Result is in x0
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
        
        // Save x0 (might contain important value)
        gen.emitStoreLocal32(tempSlot);
        
        // Load data section base into x10
        gen.emitLoadImm64(cast(ulong)dataSection.base);
        gen.emitMoveX0ToX10();
        
        // Emit inline push code  
        gen.emitInlineStackPush(cast(uint)frameDataOffset);
        
        // Restore x0
        gen.emitLoadLocal32(tempSlot);
    }
    
    /**
     * Emit inline call stack pop - decrements depth in data section, no FFI
     * Uses x8, x10 as scratch (does NOT touch x0, safe for return values)
     */
    private void emitInlinePopCall() {
        // Save x0 (return value) to stack FIRST, before we clobber it
        // Use tempSlot+4 to avoid conflicts with expression temps
        gen.emitStoreLocal32(tempSlot + 4);
        
        // Load data section base into x10 (clobbers x0, but we saved it)
        gen.emitLoadImm64(cast(ulong)dataSection.base);
        gen.emitMoveX0ToX10();
        
        // Emit inline pop code (uses x8, so we can't save return value there)
        gen.emitInlineStackPop();
        
        // Restore x0 (return value) from stack
        gen.emitLoadLocal32(tempSlot + 4);
    }
    
    /**
     * Emit bounds check: if index < 0 or index >= length, call __ctfe_trap.
     * Assumes: index in x0
     * Slice layout: { ptr: i64, length: i32, capacity: i32 } at sliceOffset (16 bytes)
     * Preserves: x0 (index)
     */
    private void emitBoundsCheck(uint sliceOffset, string fileName, uint line, uint column) {
        import codegen.native.arm64_codegen : ErrorLocData;
        
        auto errorLabel = gen.newLabel();
        auto okLabel = gen.newLabel();
        
        // Use depth-aware temp slot to avoid conflicts with nested expressions
        uint myTempSlot = tempSlot + (tempSlotDepth * 4);
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
        uint structSize = cast(uint)structDecl.structSize;
        uint structOffset = tempSlot + 16;  // After other temp slots
        import std.format : format;
        assert(structOffset + structSize <= totalLocalBytes,
            format("Struct construction temp overflows frame: offset=%d size=%d frame=%d",
                structOffset, structSize, totalLocalBytes));
        assert(structDecl.fields.length > 0,
            "Struct '" ~ structDecl.name ~ "' has no fields");
        
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
     * Native slice layout: { ptr: i64, length: i32, capacity: i32 } = NativeSliceLayout.sizeof bytes
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
    private void compileImportInit(uint sliceOffset, ImportExpression importExpr) {
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
        gen.emitStoreLocal(sliceOffset);  // store 64-bit ptr
        
        // length = len (32-bit at offset 8)
        gen.emitImm32(stencil_load_imm32, cast(int)len);
        gen.emitStoreLocal32(sliceOffset + NativeSliceLayout.LENGTH_OFFSET);  // store length
        
        // capacity = len (32-bit at offset 12)
        gen.emitImm32(stencil_load_imm32, cast(int)len);
        gen.emitStoreLocal32(sliceOffset + NativeSliceLayout.CAPACITY_OFFSET);  // store capacity
    }

    /// Initialize a slice from a string literal by storing bytes in the data section.
    private void compileStringLiteralInit(uint sliceOffset, string strVal) {
        ubyte[] strData = cast(ubyte[])strVal.dup;
        uint len = cast(uint)strData.length;

        ubyte* dataPtr = dataSection.addData(strData);
        if (dataPtr is null) {
            throw new Exception("String literal: data section full");
        }

        // ptr = dataPtr (64-bit host pointer)
        gen.emitLoadImm64(cast(ulong)dataPtr);
        gen.emitStoreLocal(sliceOffset);

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
    private void compileSliceAppend(uint sliceOffset, Expression element) {
        // Temp slots for intermediate values (use pre-allocated temp area)
        // tempSlot is at the end of the frame, with 48 bytes reserved
        uint tempElement = tempSlot;            // element value (4 bytes)
        uint tempNewCap = tempSlot + 4;         // new capacity (4 bytes)
        uint tempNewPtr = tempSlot + 8;         // new buffer ptr (8 bytes, 64-bit)
        uint tempLoopIdx = tempSlot + 16;       // copy loop index (4 bytes)
        uint tempLoopVal = tempSlot + 20;       // temp for loaded value (4 bytes)
        
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
        gen.emitStoreLocal(tempNewPtr);         // save new ptr (64-bit)
        
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
        gen.emitLoadLocal(sliceOffset);         // x0 = oldPtr (64-bit)
        gen.emitMoveX0ToX1();                   // x1 = oldPtr
        gen.emitLoadLocal32(tempLoopIdx);       // x0 = i
        gen.emitImm32(stencil_load_imm32, 4);
        gen.emitMoveX0ToX2();                   // x2 = 4
        gen.emitLoadLocal32(tempLoopIdx);       // x0 = i
        gen.emit(stencil_move_arg2_to_arg1);    // x1 = 4
        gen.emit(stencil_mul_i32);              // x0 = i * 4
        gen.emitMoveX0ToX1();                   // x1 = i * 4
        gen.emitLoadLocal(sliceOffset);         // x0 = oldPtr
        gen.emit(stencil_add_i32);              // x0 = oldPtr + i*4
        gen.emit(stencil_load_i32);             // x0 = oldPtr[i]
        gen.emitStoreLocal32(tempLoopVal);  // save loaded value
        
        // Store to new: newPtr[i] = value
        gen.emitLoadLocal(tempNewPtr);          // x0 = newPtr
        gen.emitMoveX0ToX1();                   // x1 = newPtr
        gen.emitLoadLocal32(tempLoopIdx);       // x0 = i
        gen.emitImm32(stencil_load_imm32, 4);
        gen.emitMoveX0ToX2();                   // x2 = 4
        gen.emitLoadLocal32(tempLoopIdx);       // x0 = i
        gen.emit(stencil_move_arg2_to_arg1);    // x1 = 4
        gen.emit(stencil_mul_i32);              // x0 = i * 4
        gen.emitMoveX0ToX1();                   // x1 = i * 4
        gen.emitLoadLocal(tempNewPtr);          // x0 = newPtr
        gen.emit(stencil_add_i32);              // x0 = newPtr + i*4 (dest addr)
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
        gen.emitLoadLocal(tempNewPtr);
        gen.emitStoreLocal(sliceOffset);
        
        // Update slice capacity = newCapacity
        gen.emitLoadLocal32(tempNewCap);
        gen.emitStoreLocal32(sliceOffset + NativeSliceLayout.CAPACITY_OFFSET);
        
        gen.emitBranch(doneGrowLabel);
        
        // === NO GROW PATH ===
        gen.bindLabel(noGrowLabel);
        
        gen.bindLabel(doneGrowLabel);
        
        // 4. Store element at ptr[length]
        // Calculate address: ptr + length * 4
        gen.emitLoadLocal(sliceOffset);         // x0 = ptr (64-bit)
        gen.emitMoveX0ToX1();                   // x1 = ptr
        gen.emitLoadLocal32(sliceOffset + NativeSliceLayout.LENGTH_OFFSET);   // x0 = length
        gen.emitImm32(stencil_load_imm32, 4);
        gen.emitMoveX0ToX2();                   // x2 = 4
        gen.emitLoadLocal32(sliceOffset + NativeSliceLayout.LENGTH_OFFSET);   // x0 = length
        gen.emit(stencil_move_arg2_to_arg1);    // x1 = 4
        gen.emit(stencil_mul_i32);              // x0 = length * 4
        gen.emitMoveX0ToX1();                   // x1 = length * 4
        gen.emitLoadLocal(sliceOffset);         // x0 = ptr
        gen.emit(stencil_add_i32);              // x0 = ptr + length*4
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
        size_t targetParamCount = (*funcDeclPtr).parameters.length;
        
        // Set up error recovery point - longjmp returns here on trap
        if (setjmp(ctx.errorJump) != 0) {
            // Got here via longjmp - error occurred
            return ExecutionResult.failure(ctfeErrorMessageWithStack(&ctx));
        }
        
        // Call with the target function's entry point and param count
        long result;
        switch (targetParamCount) {
            case 0:
                alias Fn0 = extern(C) long function();
                result = (cast(Fn0)(gen.base + targetEntry))();
                break;
            case 1:
                alias Fn1 = extern(C) long function(long);
                result = (cast(Fn1)(gen.base + targetEntry))(
                    args.length > 0 ? args[0] : 0);
                break;
            case 2:
                alias Fn2 = extern(C) long function(long, long);
                result = (cast(Fn2)(gen.base + targetEntry))(
                    args.length > 0 ? args[0] : 0,
                    args.length > 1 ? args[1] : 0);
                break;
            case 3:
                alias Fn3 = extern(C) long function(long, long, long);
                result = (cast(Fn3)(gen.base + targetEntry))(
                    args.length > 0 ? args[0] : 0,
                    args.length > 1 ? args[1] : 0,
                    args.length > 2 ? args[2] : 0);
                break;
            case 4:
                alias Fn4 = extern(C) long function(long, long, long, long);
                result = (cast(Fn4)(gen.base + targetEntry))(
                    args.length > 0 ? args[0] : 0,
                    args.length > 1 ? args[1] : 0,
                    args.length > 2 ? args[2] : 0,
                    args.length > 3 ? args[3] : 0);
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
        
        size_t targetEntry = (*labelPtr).offset;
        
        // Set up error recovery point
        if (setjmp(ctx.errorJump) != 0) {
            return ExecutionResult.failure(ctfeErrorMessageWithStack(&ctx));
        }
        
        // Prepend result pointer to args
        long[] fullArgs = [cast(long)resultBuf] ~ args;
        
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
