# D-to-WASM Compiler Architecture

## Overview

This compiler translates a subset of the D programming language to WebAssembly. It features:

- **Tree-sitter parsing** — robust, incremental parsing via tree-sitter-d
- **Dual backend** — WASM (via wasm3) and native ARM64 (via copy-and-patch)
- **Full CTFE** — compile-time function evaluation for mixins, static if, manifest constants
- **Rustc-style errors** — source context, column highlighting, call stacks

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           COMPILATION PIPELINE                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Source     Tree-Sitter      AST        Mixin         Type        Code    │
│    .d    ───► Parser ───► Declarations ───► Expansion ───► Check ───► Gen  │
│                                  │              │           │          │    │
│                                  │              │           │          │    │
│                                  ▼              ▼           ▼          ▼    │
│                              ast/nodes     semantic/    semantic/   codegen/│
│                              ast/expr      mixin_exp    type_check  emitter │
│                              ast/stmt      ctfe.d                   backend │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Directory Structure

```
src/
├── main.d                      # Entry point, orchestrates pipeline
├── ast/                        # Abstract Syntax Tree definitions
│   ├── nodes.d                 # Core AST: Declaration, Type, Statement, Expression bases
│   ├── expressions.d           # All expression node types
│   ├── statements.d            # All statement node types
│   └── package.d               # Public imports
├── parser/                     # Parsing (tree-sitter bridge)
│   ├── tree_sitter_bridge.d    # Main parser: TSNode → AST conversion
│   ├── tree_sitter_c.d         # C bindings for tree-sitter
│   └── tree_sitter_bridge_minimal.d  # Lightweight variant (unused)
├── semantic/                   # Semantic analysis
│   ├── symbol_table.d          # Symbol resolution, scopes
│   ├── type_checker.d          # Type checking, inference
│   ├── mixin_expander.d        # Mixin/static-if expansion, static assert
│   ├── ctfe.d                  # CTFE orchestration (lazy evaluation)
│   ├── ctfe_runtime.d          # CTFE intrinsics (__writeln, etc.)
│   ├── feature_validator.d     # Unsupported feature detection
│   └── dependency_analyzer.d   # Function dependency graph
├── codegen/                    # Code generation
│   ├── backend.d               # Backend interface + WASM/Native impls
│   ├── emitter.d               # Binary WASM emission (sections, opcodes)
│   ├── wasm.d                  # WASM constants, opcodes, encoding
│   ├── native/                 # Native ARM64 backend
│   │   ├── codegen_interface.d # Abstract interface, host functions, error handling
│   │   ├── stencil_catalog.d   # Stencil enum (all required operations)
│   │   ├── arm64_codegen.d     # ARM64-specific codegen
│   │   └── arm64/
│   │       ├── stencil_table.d # Pre-compiled ARM64 stencil bytes
│   │       └── stencils/source.d  # D source for stencils (compiled by LDC)
│   └── package.d
├── diagnostic/                 # Error reporting
│   ├── error_format.d          # Rustc-style error formatting
│   └── log.d                   # Verbosity-controlled logging
tests/
├── milestones/                 # Feature milestone tests
│   ├── milestone_01_*/         # Each milestone = test.d + config.json
│   ├── quality_*/              # Error quality tests
│   └── ...
grammar/
└── tree-sitter-d/              # Tree-sitter D grammar (submodule)
```

---

## Compilation Pipeline

### 1. Parsing (`src/parser/`)

**Entry:** `TreeSitterBridge.parseSourceFile()`

**Flow:**
```
Source code → tree-sitter-d → TSNode tree → TreeSitterBridge → Declaration[]
```

**Key functions:**
- `parseSourceFileNode()` — top-level, handles each declaration type
- `parseFunctionDeclaration()` — function → FunctionDecl
- `parseExpression()` — expression nodes → Expression subclasses
- `parseStatement()` — statement nodes → Statement subclasses
- `parseType()` — type annotations → Type subclasses

**To add a new syntax construct:**
1. Check tree-sitter-d's `node-types.json` for the node structure
2. Add case in `parseDeclarationNode()` or `parseStatement()` or `parseExpression()`
3. Create parser function (e.g., `parseStaticAssert()`)
4. Add AST node class if needed

---

### 2. AST (`src/ast/`)

**Core hierarchy:**
```
ASTNode (abstract)
├── Declaration (abstract)
│   ├── FunctionDecl       # function foo() { ... }
│   ├── StructDecl         # struct S { ... }
│   ├── ClassDecl          # class C { ... }
│   ├── EnumDecl           # enum E { ... }
│   ├── VariableDecl       # int x;
│   ├── ManifestConstantDecl  # enum x = 42;
│   ├── MixinDecl          # mixin(...);
│   ├── StaticIfDecl       # static if (...) { }
│   ├── StaticAssertDecl   # static assert(...);
│   └── ImportDecl         # import std.stdio;
├── Statement (abstract)
│   ├── CompoundStatement  # { stmt; stmt; }
│   ├── IfStatement        # if (cond) { }
│   ├── WhileStatement     # while (cond) { }
│   ├── ForStatement       # for (;;) { }
│   ├── ReturnStatement    # return expr;
│   ├── ExpressionStatement  # expr;
│   └── VariableDeclarationStatement  # int x = 5;
├── Expression (abstract)
│   ├── LiteralExpression  # 42, "hello", true
│   ├── IdentifierExpression  # foo
│   ├── BinaryExpression   # a + b
│   ├── UnaryExpression    # -x, !x
│   ├── CallExpression     # foo(args)
│   ├── IndexExpression    # arr[i]
│   ├── MemberExpression   # s.field
│   ├── AssignmentExpression  # x = y, x += y
│   ├── CastExpression     # cast(int)x
│   └── ArrayLiteralExpression  # [1, 2, 3]
└── Type (abstract)
    ├── BasicType          # int, bool, void, etc.
    ├── ArrayType          # int[], int[3]
    ├── PointerType        # int*
    ├── FunctionType       # int function(int)
    └── UserType           # struct/class names
```

**To add a new AST node:**
1. Add class to appropriate file (`nodes.d`, `expressions.d`, `statements.d`)
2. Include all necessary fields
3. Implement `toString()` for debugging
4. Add source location tracking

---

### 3. Mixin/Static Expansion (`src/semantic/mixin_expander.d`)

**Entry:** `MixinExpander.expandMixins()`

**Happens before type checking.** Transforms the AST by:
- Evaluating `mixin("code")` via CTFE, parsing result, splicing into AST
- Evaluating `static if (cond)` conditions, keeping only the true branch
- Evaluating `static assert(cond, msg)`, failing compilation if false

**Key methods:**
- `expandMixin()` — CTFE evaluate → parse → splice
- `expandStaticIf()` — evaluate condition → select branch
- `evaluateStaticAssert()` — evaluate condition → error if false
- `evaluateStaticIfCondition()` — handles literals, comparisons, manifest constants

**To add a new compile-time construct:**
1. Add AST node (e.g., `StaticAssertDecl`)
2. Add parsing in `tree_sitter_bridge.d`
3. Add handling in `expandMixins()` loop
4. Implement evaluation function

---

### 4. Symbol Table (`src/semantic/symbol_table.d`)

**Entry:** `SymbolTable` + `SymbolCollector`

**Provides:**
- Scope management (enter/exit scope)
- Symbol registration and lookup
- Built-in symbols (`__ctfe`, `__writeln`, etc.)

**Key classes:**
- `Symbol` — name, kind, type, declaration reference
- `Scope` — parent pointer, symbol map
- `SymbolTable` — scope stack, global scope, builtins

**Symbol kinds:** Variable, Function, Type, Parameter, Field

**To add a built-in:**
1. Add to `addBuiltinSymbols()` in `symbol_table.d`
2. If it's a CTFE intrinsic, add handling in `ctfe_runtime.d`

---

### 5. Type Checking (`src/semantic/type_checker.d`)

**Entry:** `TypeChecker.checkDeclarations()`

**Validates:**
- Expression types match expected types
- Function return types are correct
- Binary operators have compatible operands
- Array indexing uses integers
- Struct field access is valid

**Key methods:**
- `checkFunctionDeclaration()` — params, body, return type
- `checkExpression()` → `Type` — infers/validates expression type
- `checkStatement()` — control flow, variable declarations
- `checkTypeCompatibility()` — can A be assigned to B?

**To support a new type or operation:**
1. Add type class to `ast/nodes.d` if needed
2. Add handling in `checkExpression()` for expressions using the type
3. Update `checkTypeCompatibility()` for conversions
4. Update `getExpressionType()` for type inference

---

### 6. CTFE (`src/semantic/ctfe.d`)

**Entry:** `CTFEEvaluator`

**Lazy evaluation model:**
- Manifest constants (`enum x = expr`) are evaluated on-demand
- First access triggers compilation + execution
- Results are cached

**Flow:**
```
Expression → find dependencies → compile to WASM/Native → execute → return value
```

**Key methods:**
- `evaluateManifestConstant()` — compile + run, cache result
- `evaluateFunction()` — compile function + dependencies
- `compileAndExecute()` — backend.compile() → call()

**Backends:**
- `WASMBackend` — compile to WASM, run with wasm3
- `NativeBackend` — compile to ARM64, execute directly

**CTFE intrinsics** (in `ctfe_runtime.d`):
- `__writeln` — debug output during CTFE
- `__ctfe_alloc` — allocate memory in CTFE arena
- `__ctfe_write_str` — write string to CTFE memory

**To add a CTFE intrinsic:**
1. Register symbol in `symbol_table.d` `addBuiltinSymbols()`
2. Add host function in `ctfe_runtime.d`
3. Register in backend's host function table

---

### 7. Code Generation (`src/codegen/`)

#### 7a. WASM Emission (`emitter.d`)

**Entry:** `BinaryEmitter.emit()`

**Phases:**
1. **Collect** — gather all functions, build indices
2. **Types** — emit type section (function signatures)
3. **Imports** — emit import section (host functions)
4. **Functions** — emit function section (type indices)
5. **Memory** — emit memory section
6. **Globals** — emit globals ($heap_ptr, $sp)
7. **Exports** — emit export section
8. **Code** — emit function bodies (instructions)
9. **Data** — emit data section (string literals, array data)

**Key methods:**
- `emitFunction()` — single function body
- `emitExpression()` → generates WASM instructions
- `emitStatement()` — control flow, locals

**To add a new WASM feature:**
1. Add opcode to `wasm.d` if needed
2. Implement in `emitExpression()` or `emitStatement()`
3. Handle any new value types in type mapping

#### 7b. Native Backend (`codegen/native/`)

**Entry:** `NativeBackend.compile()`

**Uses copy-and-patch:**
1. Pre-compiled stencils (tiny code templates with holes)
2. At compile time: copy stencil, patch holes with actual values
3. Result: directly executable ARM64 machine code

**Key files:**
- `stencil_catalog.d` — enum of all stencils needed
- `arm64_codegen.d` — ARM64 code generator (emit + patch)
- `arm64/stencil_table.d` — actual stencil bytes
- `codegen_interface.d` — abstract interface, host functions, error context

**Memory model:**
- Shadow stack for locals/structs (grows down from stack pointer)
- Host function calls via function table
- Error handling via setjmp/longjmp

**To add ARM64 support for a feature:**
1. Add stencil to `stencil_catalog.d` enum
2. Write stencil D source in `arm64/stencils/source.d`
3. Compile and extract bytes to `stencil_table.d`
4. Add emission code in `arm64_codegen.d`

**To add x86_64 backend:**
1. Create `x86_64/stencil_table.d` with all stencils
2. Create `X86_64CodeGen` implementing the interface
3. Add case in `createBackend()`

---

## Error Handling

**Error types:**
- `ParseError` — syntax errors (from parser)
- `MixinError` — mixin/static-if evaluation failures
- `TypeError` — type checking failures
- `EmitError` — code generation failures
- `CTFEError` — CTFE execution failures

**Error formatting** (`diagnostic/error_format.d`):
```
error: message
  --> file.d:line:column
  |
N | source line
  |     ^^^
```

**Runtime CTFE errors** include call stack with source locations.

---

## Common Modification Scenarios

### Adding a New Operator

1. **Parser** (`tree_sitter_bridge.d`):
   - Find where binary/unary expressions are parsed
   - Add case for new operator token

2. **AST** (`expressions.d`):
   - Add enum value to `BinaryExpression.Operator` or `UnaryExpression.Operator`

3. **Type Checker** (`type_checker.d`):
   - Add case in `checkBinaryExpression()` or `checkUnaryExpression()`
   - Define valid operand types and result type

4. **WASM Emitter** (`emitter.d`):
   - Add case in `emitBinaryExpression()` or `emitUnaryExpression()`
   - Emit appropriate WASM opcode

5. **Native Backend** (`arm64_codegen.d`):
   - Add stencil if needed
   - Add case in expression compilation

### Adding a New Statement Type

1. **AST** (`statements.d`):
   - Create new Statement subclass

2. **Parser** (`tree_sitter_bridge.d`):
   - Check tree-sitter node type in `node-types.json`
   - Add case in `parseStatement()`
   - Implement `parseNewStatement()`

3. **Type Checker** (`type_checker.d`):
   - Add case in `checkStatement()`

4. **WASM Emitter** (`emitter.d`):
   - Add case in `emitStatement()`

5. **Native Backend** (`backend.d`):
   - Add case in statement compilation

### Adding a New Declaration Type

1. **AST** (`nodes.d`):
   - Create new Declaration subclass

2. **Parser** (`tree_sitter_bridge.d`):
   - Add case in `parseDeclarationNode()` AND in top-level parsing
   - Implement `parseNewDecl()`

3. **Symbol Table** (`symbol_table.d`):
   - Update `SymbolCollector` if it introduces symbols

4. **Type Checker** (`type_checker.d`):
   - Add case in `checkDeclaration()` if needed

5. **Mixin Expander** (`mixin_expander.d`):
   - Add handling if it's compile-time evaluated

### Adding a New Type

1. **AST** (`nodes.d`):
   - Create new Type subclass or add to BasicType.Kind

2. **Parser** (`tree_sitter_bridge.d`):
   - Add case in `parseType()`

3. **Type Checker** (`type_checker.d`):
   - Update type compatibility logic
   - Update `getExpressionType()` for literals

4. **WASM** (`wasm.d`, `emitter.d`):
   - Map to WASM value type
   - Handle in expression emission

5. **Native Backend**:
   - Update register allocation if needed
   - Add type-specific stencils

### Adding a CTFE Intrinsic

1. **Symbol Table** (`symbol_table.d`):
   - Register in `addBuiltinSymbols()`

2. **CTFE Runtime** (`ctfe_runtime.d`):
   - Implement host function

3. **WASM Backend** (`backend.d`):
   - Register as WASM import

4. **Native Backend** (`codegen_interface.d`):
   - Add to `HostFunctionTable`

---

## Testing

**Test structure:**
```
tests/milestones/
├── milestone_NN_feature_name/
│   ├── test.d          # D source code
│   ├── config.json     # Test configuration
│   └── expected.txt    # Expected output (for error tests)
```

**Config options:**
```json
{
  "name": "feature_name",
  "description": "What this tests",
  "type": "wasm_exec",        // or "compile_error"
  "entry": "result",          // function to call (default: main)
  "expected_result": 42,      // for wasm_exec
  "capability": "Feature X"   // documentation
}
```

**Run tests:**
```bash
./test_runner.sh           # All tests
./test_runner.sh -v        # Verbose
./d2wasm -r test.d         # Compile and run single file
```

---

## Key Invariants

1. **Mixin expansion happens before type checking** — CTFE needs untyped AST
2. **CTFE is lazy** — manifest constants evaluated on first access
3. **Symbol table scopes are stack-based** — enter/exit must be balanced
4. **Native backend uses shadow stack** — structs/arrays go on shadow stack, not registers
5. **WASM memory layout**: heap grows up from `$heap_ptr`, shadow stack grows down from `$sp`

---

## Performance Notes

- Tree-sitter parsing is fast and incremental
- CTFE results are cached to avoid re-evaluation
- Native backend avoids interpreter overhead for CTFE-heavy code
- Stencil-based codegen is O(1) per operation (no runtime instruction selection)

---

## Future Work

- [ ] x86_64 native backend
- [ ] Template support
- [ ] More string operations
- [ ] Module system
- [ ] Debug info (DWARF)
- [ ] Incremental compilation
