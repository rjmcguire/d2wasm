# D-to-WASM Compiler Technical Architecture

## Compiler Pipeline Details

### Stage 1: Tree-sitter Parsing

**Input**: D source code (.d files)
**Output**: Parse tree (tree-sitter nodes)

**Key Components**:
```rust
// Tree-sitter grammar rules (excerpt)
module.exports = grammar({
  name: 'd',
  
  rules: {
    source_file: $ => repeat($.declaration),
    
    declaration: $ => choice(
      $.function_declaration,
      $.class_declaration,
      $.struct_declaration,
      $.interface_declaration,
      $.variable_declaration
    ),
    
    function_declaration: $ => seq(
      optional($.attributes),
      $.return_type,
      $.identifier,
      $.parameter_list,
      $.function_body
    ),
    
    class_declaration: $ => seq(
      'class',
      $.identifier,
      optional(seq(':', $.base_class_list)),
      $.class_body
    )
    // ... more rules
  }
});
```

**Incremental Parsing Strategy**:
- Use tree-sitter's incremental parsing for file changes
- Maintain parse tree cache for unchanged regions
- Re-parse only modified syntax nodes and dependencies

### Stage 2: AST Construction

**Input**: Tree-sitter parse tree
**Output**: Semantic AST with type information

**AST Node Hierarchy**:
```d
// Core AST node types
abstract class ASTNode {
    SourceLocation location;
    ASTNode parent;
}

class Declaration : ASTNode {
    string name;
    Visibility visibility;
    Attribute[] attributes;
}

class FunctionDecl : Declaration {
    Type returnType;
    Parameter[] parameters;
    Statement[] body;
    bool isPure, isNothrow, isSafe;
}

class ClassDecl : Declaration {
    ClassDecl baseClass;
    InterfaceDecl[] interfaces;
    Declaration[] members;
    Constructor[] constructors;
}

class StructDecl : Declaration {
    FieldDecl[] fields;
    FunctionDecl[] methods;
}

// Type system
abstract class Type {
    uint size();
    string mangled_name();
}

class PrimitiveType : Type {
    enum Kind { Bool, Int8, Int16, Int32, Int64, Float32, Float64, Char }
    Kind kind;
}

class PointerType : Type {
    Type pointeeType;
}

class ArrayType : Type {
    Type elementType;
    bool isDynamic;
    size_t staticSize; // if !isDynamic
}

class StructType : Type {
    StructDecl declaration;
    FieldDecl[] fields;
}

class ClassType : Type {
    ClassDecl declaration;
    FieldDecl[] fields;
    FunctionDecl[] methods;
    VTable vtable;
}
```

### Stage 3: Semantic Analysis

**Input**: Raw AST from tree-sitter conversion
**Output**: Validated AST with complete type information

**Symbol Table Management**:
```d
class SymbolTable {
    SymbolTable parent;
    Symbol[string] symbols;
    
    void enterScope() { /* create new scope */ }
    void exitScope() { /* return to parent scope */ }
    Symbol lookup(string name) { /* search hierarchy */ }
    void declare(string name, Symbol symbol) { /* add to current scope */ }
}

class Symbol {
    string name;
    Type type;
    Declaration declaration;
    SymbolKind kind; // function, variable, type, etc.
}
```

**Type Checking Process**:
1. **Declaration Pass**: Build symbol table, no type resolution
2. **Type Resolution Pass**: Resolve all type references
3. **Type Checking Pass**: Verify type compatibility, inheritance
4. **CTFE Pass**: Evaluate compile-time function execution
5. **Contract Validation**: Verify in/out contracts are type-safe

**Interface Resolution**:
```d
class InterfaceResolver {
    // Build virtual function tables for classes with interfaces
    VTable buildVTable(ClassDecl classDecl) {
        VTable vtable = new VTable();
        
        // Add all interface methods
        foreach (iface; classDecl.interfaces) {
            foreach (method; iface.methods) {
                auto impl = findImplementation(classDecl, method);
                vtable.addEntry(method.mangledName, impl);
            }
        }
        
        // Add class virtual methods
        foreach (method; classDecl.virtualMethods) {
            vtable.addEntry(method.mangledName, method);
        }
        
        return vtable;
    }
}
```

### Stage 4: WASM IR Generation

**Input**: Validated semantic AST
**Output**: High-level WASM intermediate representation

**WASM IR Design**:
```d
// WASM IR nodes - high level representation before lowering to WAT
abstract class WasmIR {
    WasmType type;
}

class WasmFunction : WasmIR {
    string name;
    WasmParam[] parameters;
    WasmType returnType;
    WasmLocal[] locals;
    WasmInstruction[] instructions;
}

class WasmStruct : WasmIR {
    string name;
    WasmField[] fields;
    uint totalSize;
    uint alignment;
}

class WasmInstruction : WasmIR {
    enum Opcode {
        // Stack manipulation
        LocalGet, LocalSet, GlobalGet, GlobalSet,
        
        // Arithmetic
        I32Add, I32Sub, I32Mul, I32Div, I32Rem,
        I64Add, I64Sub, I64Mul, I64Div, I64Rem,
        F32Add, F32Sub, F32Mul, F32Div,
        F64Add, F64Sub, F64Mul, F64Div,
        
        // Memory
        I32Load, I32Store, I64Load, I64Store,
        F32Load, F32Store, F64Load, F64Store,
        
        // Control flow
        Block, Loop, If, Br, BrIf, Call, CallIndirect,
        Return, Unreachable,
        
        // Conversions
        I32WrapI64, I64ExtendI32, F32DemoteF64, F64PromoteF32
    }
    
    Opcode opcode;
    WasmOperand[] operands;
}
```

**Function Translation Strategy**:
```d
class FunctionTranslator {
    WasmFunction translateFunction(FunctionDecl func) {
        auto wasmFunc = new WasmFunction(func.mangledName);
        
        // Translate parameters
        foreach (param; func.parameters) {
            wasmFunc.parameters ~= translateParameter(param);
        }
        
        // Translate return type
        wasmFunc.returnType = translateType(func.returnType);
        
        // Translate function body
        foreach (stmt; func.body) {
            wasmFunc.instructions ~= translateStatement(stmt);
        }
        
        return wasmFunc;
    }
    
    WasmInstruction[] translateStatement(Statement stmt) {
        switch (stmt.kind) {
            case StatementKind.Assignment:
                return translateAssignment(cast(AssignmentStmt)stmt);
            case StatementKind.FunctionCall:
                return translateFunctionCall(cast(CallStmt)stmt);
            case StatementKind.If:
                return translateIf(cast(IfStmt)stmt);
            case StatementKind.While:
                return translateWhile(cast(WhileStmt)stmt);
            default:
                assert(0, "Unsupported statement type");
        }
    }
}
```

### Stage 5: Memory Layout Manager

**Struct Layout**:
```d
class MemoryLayoutManager {
    struct FieldLayout {
        uint offset;
        uint size;
        uint alignment;
        Type fieldType;
    }
    
    FieldLayout[] calculateStructLayout(StructDecl structDecl) {
        FieldLayout[] layout;
        uint currentOffset = 0;
        
        foreach (field; structDecl.fields) {
            auto fieldSize = field.type.size();
            auto fieldAlign = field.type.alignment();
            
            // Align offset for this field
            currentOffset = alignTo(currentOffset, fieldAlign);
            
            layout ~= FieldLayout(currentOffset, fieldSize, fieldAlign, field.type);
            currentOffset += fieldSize;
        }
        
        return layout;
    }
    
    uint alignTo(uint offset, uint alignment) {
        return (offset + alignment - 1) & ~(alignment - 1);
    }
}
```

**Class Object Layout**:
```d
class ClassLayoutManager {
    // Class objects: [vtable_ptr][field1][field2]...[fieldN]
    struct ClassLayout {
        uint vtableOffset = 0;          // Always at offset 0
        FieldLayout[] fieldLayouts;
        uint totalSize;
    }
    
    ClassLayout calculateClassLayout(ClassDecl classDecl) {
        ClassLayout layout;
        layout.vtableOffset = 0;
        
        uint currentOffset = size_t.sizeof; // Space for vtable pointer
        
        // Include base class fields first
        if (classDecl.baseClass) {
            auto baseLayout = calculateClassLayout(classDecl.baseClass);
            currentOffset = baseLayout.totalSize;
            layout.fieldLayouts = baseLayout.fieldLayouts.dup;
        }
        
        // Add this class's fields
        foreach (field; classDecl.fields) {
            auto fieldSize = field.type.size();
            auto fieldAlign = field.type.alignment();
            
            currentOffset = alignTo(currentOffset, fieldAlign);
            layout.fieldLayouts ~= FieldLayout(currentOffset, fieldSize, fieldAlign, field.type);
            currentOffset += fieldSize;
        }
        
        layout.totalSize = currentOffset;
        return layout;
    }
}
```

### Stage 6: WASM Code Optimization

**Optimization Passes**:
1. **Dead Code Elimination**: Remove unused functions and variables
2. **Constant Propagation**: Replace variables with compile-time constants
3. **Function Inlining**: Inline small functions for performance
4. **Tail Call Optimization**: Convert tail calls to loops where possible
5. **Memory Access Optimization**: Optimize struct field accesses

```d
class ConstantPropagationPass {
    void run(WasmModule module) {
        foreach (func; module.functions) {
            optimizeFunction(func);
        }
    }
    
    void optimizeFunction(WasmFunction func) {
        bool changed = true;
        while (changed) {
            changed = false;
            
            for (int i = 0; i < func.instructions.length; i++) {
                auto instr = func.instructions[i];
                
                // Look for constant operations
                if (instr.opcode == WasmInstruction.Opcode.I32Add) {
                    if (isConstant(instr.operands[0]) && isConstant(instr.operands[1])) {
                        auto result = evaluateConstant(instr);
                        func.instructions[i] = result;
                        changed = true;
                    }
                }
            }
        }
    }
}
```

### Stage 7: WAT Generation

**Final Code Emission**:
```d
class WATEmitter {
    string emitModule(WasmModule module) {
        auto wat = appender!string();
        
        wat.put("(module\n");
        
        // Emit memory declaration
        wat.put("  (memory 1)\n");
        
        // Emit imports
        foreach (import_; module.imports) {
            wat.put(emitImport(import_));
        }
        
        // Emit globals
        foreach (global; module.globals) {
            wat.put(emitGlobal(global));
        }
        
        // Emit functions
        foreach (func; module.functions) {
            wat.put(emitFunction(func));
        }
        
        // Emit exports
        foreach (export_; module.exports) {
            wat.put(emitExport(export_));
        }
        
        wat.put(")\n");
        return wat.data;
    }
    
    string emitFunction(WasmFunction func) {
        auto wat = appender!string();
        
        wat.put("  (func $" ~ func.name);
        
        // Parameters
        foreach (param; func.parameters) {
            wat.put(" (param $" ~ param.name ~ " " ~ param.type.toString() ~ ")");
        }
        
        // Return type
        if (func.returnType != WasmType.Void) {
            wat.put(" (result " ~ func.returnType.toString() ~ ")");
        }
        
        wat.put("\n");
        
        // Locals
        foreach (local; func.locals) {
            wat.put("    (local $" ~ local.name ~ " " ~ local.type.toString() ~ ")\n");
        }
        
        // Instructions
        foreach (instr; func.instructions) {
            wat.put(emitInstruction(instr));
        }
        
        wat.put("  )\n");
        return wat.data;
    }
}
```

## Build System Integration

**Project Structure**:
```
d-to-wasm-compiler/
├── src/
│   ├── parser/           # Tree-sitter integration
│   ├── ast/              # AST node definitions
│   ├── semantic/         # Type checking, symbol resolution
│   ├── codegen/          # WASM IR generation
│   ├── optimizer/        # Optimization passes
│   ├── emitter/          # WAT/WASM output
│   └── main.d            # CLI interface
├── grammar/              # Tree-sitter grammar files
├── runtime/              # WASM runtime helpers
├── tests/                # Test suite
├── examples/             # Example D programs
└── tools/                # Development tools
```

**Build Integration**:
```d
// Command line interface
int main(string[] args) {
    auto options = parseCommandLine(args);
    
    auto compiler = new DToWasmCompiler(options);
    
    foreach (sourceFile; options.sourceFiles) {
        compiler.addSource(sourceFile);
    }
    
    auto result = compiler.compile();
    
    if (result.success) {
        writeOutput(options.outputFile, result.wasmModule);
        return 0;
    } else {
        writeErrors(result.errors);
        return 1;
    }
}
```

This technical architecture provides the detailed foundation for implementing the D-to-WASM compiler, with clear separation of concerns and well-defined interfaces between components.