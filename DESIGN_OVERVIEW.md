# D-to-WASM Compiler Design Overview

## Project Vision

Build a focused, high-performance D language compiler targeting WebAssembly, emphasizing simplicity and predictability by excluding complex runtime features (templates, threads, modules, GC).

## Core Design Principles

### 1. **Simplicity First**
- Single compilation unit model
- Predictable memory layout
- Direct feature mapping to WASM primitives
- No runtime surprises

### 2. **Performance Focus**
- Manual memory management for deterministic performance
- Compile-time optimizations (CTFE, constant folding)
- Efficient WASM instruction generation
- Fast compilation times

### 3. **Developer Experience**
- Clear error messages with source location mapping
- Incremental compilation support (future)
- Comprehensive debugging information
- IDE integration hooks

## Supported Language Subset

### ✅ **Core Features**
```d
// Basic types and variables
int x = 42;
double y = 3.14;
bool flag = true;
char c = 'A';

// Functions with overloading
int add(int a, int b) { return a + b; }
double add(double a, double b) { return a + b; }

// Structs and classes
struct Point { int x, y; }
class Circle {
    Point center;
    int radius;
    this(int x, int y, int r) { /* constructor */ }
    int area() { return 3 * radius * radius; }
}

// Arrays (manual memory management)
int[] dynamic_array = cast(int[])malloc(10 * int.sizeof);
int[5] static_array = [1, 2, 3, 4, 5];

// Control flow
if (condition) { /* ... */ }
while (running) { /* ... */ }
foreach (element; array) { /* ... */ }

// Interfaces and inheritance
interface Drawable { void draw(); }
class Shape : Drawable { void draw() { /* ... */ } }

// Function pointers and delegates
int function(int) fp = &myFunction;
int delegate(int) dg = (x) => x * 2;

// Enums and unions
enum Color { Red = 1, Green = 2, Blue = 3 }
union Data { int i; float f; char[4] bytes; }

// Operator overloading
Vector opBinary(string op)(Vector rhs) if (op == "+") { /* ... */ }

// Compile-time features
enum fibonacci_10 = ctfe_fibonacci(10); // CTFE
version(WebAssembly) { /* conditional compilation */ }

// Contracts and attributes
@safe pure nothrow int safeFn(int x) { return x * 2; }
int divide(int a, int b)
in { assert(b != 0); }
out(result) { assert(result == a / b); }
do { return a / b; }
```

### 🚫 **Excluded Features**
- Templates and generics
- Garbage collection (use manual memory management)
- Threading and concurrency
- Module system (single compilation unit)
- String mixins (too complex for initial version)
- Dynamic loading

## Architecture Overview

```
Source Code (.d)
       ↓
┌─────────────────┐
│  Tree-sitter    │ ← Incremental parsing
│  Parser         │
└─────────────────┘
       ↓
┌─────────────────┐
│  AST Builder    │ ← Build semantic tree
│                 │
└─────────────────┘
       ↓
┌─────────────────┐
│  Semantic       │ ← Type checking, symbol resolution
│  Analyzer       │   Interface verification, CTFE
└─────────────────┘
       ↓
┌─────────────────┐
│  WASM IR        │ ← High-level WASM intermediate repr.
│  Generator      │   Memory layout, function signatures
└─────────────────┘
       ↓
┌─────────────────┐
│  WASM Optimizer │ ← Dead code elimination, inlining
│                 │   Constant propagation
└─────────────────┘
       ↓
┌─────────────────┐
│  WAT/WASM       │ ← Final binary generation
│  Emitter        │
└─────────────────┘
       ↓
    Output (.wat/.wasm)
```

## Technical Specifications

### Memory Model
- **Linear memory**: Single WASM memory instance
- **Stack allocation**: Function-local variables
- **Heap allocation**: Manual malloc/free style (no GC)
- **Object layout**: Predictable struct/class field ordering

### Function Calling Convention
- **Name mangling**: `functionName_param1Type_param2Type`
- **Return values**: Single return via WASM function result
- **Parameters**: Direct parameter passing where possible
- **Overloading**: Compile-time resolution with mangled names

### Type System Mapping
```d
// D Type          → WASM Type
bool              → i32 (0/1)
byte, ubyte       → i32
short, ushort     → i32
int, uint         → i32
long, ulong       → i64
float             → f32
double            → f64
char              → i32
pointers          → i32 (memory offset)
arrays            → (ptr: i32, len: i32)
structs           → sequential memory layout
classes           → ptr to heap-allocated data
```

### Interface Implementation
- **Virtual tables**: Function pointer arrays
- **Interface dispatch**: Runtime function table lookup
- **Multiple inheritance**: Interface combination (no diamond problem)

## Development Phases

### Phase 1: Foundation (Months 1-2)
**Goal**: Basic compilation pipeline with simple features

**Deliverables**:
- Tree-sitter grammar for D subset
- AST data structures and builder
- Basic semantic analysis (symbol resolution, type checking)
- Simple WASM code generation for:
  - Functions with basic types
  - Control flow (if/while/for)
  - Basic arithmetic operations

**Success Criteria**:
```d
int add(int a, int b) { return a + b; }
int main() {
    int x = 5;
    int y = 10;
    return add(x, y);
}
```
Compiles to working WASM.

### Phase 2: Data Structures (Months 2-3)
**Goal**: Structs, classes, and memory management

**Deliverables**:
- Struct field layout and access
- Class constructor/destructor support
- Basic inheritance (single inheritance)
- Manual memory management (malloc/free integration)
- Array support (static and dynamic)

**Success Criteria**:
```d
class Point {
    int x, y;
    this(int x, int y) { this.x = x; this.y = y; }
    int distance() { return x*x + y*y; }
}

int main() {
    Point p = new Point(3, 4);
    return p.distance(); // Should return 25
}
```

### Phase 3: Advanced Features (Months 4-5)
**Goal**: Interfaces, operator overloading, function pointers

**Deliverables**:
- Interface virtual table implementation
- Operator overloading compilation
- Function pointers and delegates
- Enum and union support
- Advanced control flow (foreach, switch)

**Success Criteria**:
```d
interface Drawable { void draw(); }
class Circle : Drawable {
    void draw() { /* implementation */ }
}

int main() {
    Drawable d = new Circle();
    d.draw(); // Virtual dispatch works
    return 0;
}
```

### Phase 4: Quality & Optimization (Month 6)
**Goal**: Production readiness and performance

**Deliverables**:
- CTFE implementation for constants
- Contract and assertion support
- Optimization passes (dead code elimination, constant folding)
- Comprehensive error messages
- Debug information generation

**Success Criteria**:
- Passes comprehensive test suite
- Performance benchmarks vs other compilers
- Clear error messages for all failure modes
- Integration with development tools

## Success Metrics

### Performance Targets
- **Compilation speed**: < 1 second for 10k lines of code
- **Generated WASM size**: Within 20% of hand-optimized WAT
- **Runtime performance**: Within 15% of equivalent C code compiled to WASM

### Quality Targets
- **Test coverage**: 95%+ line coverage of compiler code
- **Error handling**: Graceful failure with helpful messages for all invalid input
- **Standards compliance**: Correct implementation of all supported D features

## Next Steps

1. **Set up project structure** with build system and testing framework
2. **Implement tree-sitter grammar** for D language subset
3. **Design AST data structures** for semantic representation
4. **Create initial lexer/parser integration** with basic error handling
5. **Implement minimal code generator** for functions and basic types

This design provides a clear, focused path to a working D-to-WASM compiler in 6 months while maintaining high engineering standards.