# AGENTS.md - D-to-WASM Compiler Project Ethos

## Project Mission

Build a **focused, high-performance D-to-WASM compiler** that proves D can be as fast to compile as it is to run, while maintaining the language's expressiveness through a carefully chosen subset.

## Core Principles

### 🎯 **Principle 1: Simplicity Through Subtraction**
We achieve power by removing complexity, not adding features.

**MUST**: Focus relentlessly on the defined feature subset
**MUST**: Reject feature creep - every addition requires explicit design review  
**MUST NOT**: Add features just because "D supports it"
**SHOULD**: Always ask "does this serve fast WASM compilation?"

### 🔧 **Principle 2: Clean Separation of Concerns**
Parse everything, validate semantically, compile what's supported.

**MUST**: Use gdamore's tree-sitter-d grammar unmodified as dependency
**MUST**: Handle feature restrictions in semantic validation, not parsing
**MUST**: Provide exceptional error messages with helpful alternatives
**MUST NOT**: Fork or modify the tree-sitter grammar
**SHOULD**: Keep parsing, validation, and codegen as separate phases

### ⚡ **Principle 3: Performance First**
Fast compilation enables fast iteration enables better code.

**MUST**: Target < 500ms compilation for 1000 lines of D code
**MUST**: Measure and optimize compilation speed at every phase
**MUST**: Choose simple algorithms over complex ones
**MUST NOT**: Sacrifice compilation speed for marginal code generation improvements
**SHOULD**: Profile and benchmark regularly

### 📚 **Principle 4: Exceptional Developer Experience**
The compiler is a tool for humans - treat it that way.

**MUST**: Provide error messages that teach, not just complain
**MUST**: Include helpful suggestions for unsupported features
**MUST**: Show source locations and context for all diagnostics
**MUST**: Support incremental compilation (future requirement)
**MUST NOT**: Crash on invalid input - always fail gracefully
**SHOULD**: Make error messages feel like a helpful mentor

## Feature Philosophy

### ✅ **What We Support (and Why)**

#### **Core Language**
```d
// Functions with overloading - essential for expressive APIs
int add(int a, int b);
double add(double a, double b);

// Structs and classes - object-oriented programming without complexity
class Circle { int radius; int area() { return 3 * radius * radius; } }

// Manual memory management - predictable performance
Circle c = cast(Circle)malloc(Circle.sizeof);
```

**Rationale**: These features provide 90% of D's expressiveness while mapping cleanly to WASM.

#### **Advanced Features**
```d
// Interfaces - polymorphism without inheritance complexity
interface Drawable { void draw(); }

// CTFE - compile-time optimization without runtime cost
enum pi_squared = ctfe_multiply(3.14159, 3.14159);

// Contracts - documentation that executes
int divide(int a, int b) in { assert(b != 0); } do { return a / b; }
```

**Rationale**: These add significant value while remaining deterministic and WASM-friendly.

### 🚫 **What We Exclude (and Why)**

#### **Templates**
```d
// NOT SUPPORTED:
T max(T)(T a, T b) { return a > b ? a : b; }

// ALTERNATIVE:
int max_int(int a, int b) { return a > b ? a : b; }
double max_double(double a, double b) { return a > b ? a : b; }
```

**Rationale**: Templates cause compilation complexity and code bloat. Function overloading covers 95% of template use cases.

#### **Garbage Collection**
```d
// NOT SUPPORTED:
int[] array = new int[100];  // GC allocation

// ALTERNATIVE:
int[] array = cast(int[])malloc(100 * int.sizeof);
scope(exit) free(array.ptr);
```

**Rationale**: GC adds runtime unpredictability and WASM integration complexity. Manual memory management is explicit and performant.

#### **Modules**
```d
// NOT SUPPORTED:
import std.stdio;
module mypackage.mymodule;

// ALTERNATIVE:
// Single file compilation with all dependencies included
```

**Rationale**: Module system adds compilation complexity. Single-file compilation is simpler and faster.

#### **Threading**
```d
// NOT SUPPORTED:
spawn(&worker_function);
shared int counter;

// ALTERNATIVE:
// Single-threaded deterministic execution
```

**Rationale**: Threading adds complexity and WASM threading support is still evolving. Single-threaded is simpler and more portable.

## Implementation Rules

### 🏗️ **Architecture Constraints**

**MUST**: Maintain this exact pipeline:
```
D Source → Tree-sitter Parse → Full AST → Feature Validation → Semantic Analysis → WASM IR → Optimization → WAT/WASM
```

**MUST**: Keep each phase independent and testable
**MUST**: Use visitor pattern for AST traversal  
**MUST NOT**: Mix parsing concerns with semantic concerns
**SHOULD**: Design for incremental compilation from day one

### 📝 **Code Quality Standards**

**MUST**: Write comprehensive unit tests for every compiler phase
**MUST**: Include integration tests with real D programs
**MUST**: Document all public APIs with examples
**MUST**: Use clear, descriptive variable and function names
**MUST NOT**: Optimize prematurely - profile first
**SHOULD**: Aim for 90%+ test coverage

### 🚨 **Error Handling Philosophy**

**MUST**: Collect multiple errors before failing compilation
**MUST**: Provide specific source location information
**MUST**: Include helpful suggestions in error messages
**MUST**: Differentiate between syntax errors and feature restrictions

**Example Error Message Structure**:
```
error: Feature not supported in D-to-WASM subset
  --> matrix.d:5:13
   |
 5 |     T max(T)(T a, T b) { return a > b ? a : b; }
   |             ^^^^^^^^^^
   |
note: Templates add compilation complexity and code bloat
help: Use function overloading instead:
      int max(int a, int b) { return a > b ? a : b; }
      double max(double a, double b) { return a > b ? a : b; }
help: See documentation: https://d-to-wasm.dev/alternatives/templates
```

### 🔄 **Development Workflow**

**MUST**: Write tests before implementing features (TDD)
**MUST**: Benchmark performance impact of changes
**MUST**: Update documentation when changing behavior
**MUST**: Review all changes against these principles
**MUST NOT**: Merge without passing all tests
**SHOULD**: Use incremental development with working milestones

## Decision Framework

When facing any design choice, apply this hierarchy:

1. **Does this serve fast WASM compilation?** (Primary goal)
2. **Does this maintain simplicity?** (Core value)  
3. **Does this improve developer experience?** (User focus)
4. **Is this the simplest approach that works?** (YAGNI principle)
5. **Can we measure the impact?** (Data-driven decisions)

### 🤔 **Decision Examples**

**Q**: Should we support `auto` return type inference?
**A**: YES - improves developer experience without compilation complexity

**Q**: Should we support template constraints `if (...)`?  
**A**: NO - templates aren't supported, constraints add no value

**Q**: Should we optimize for minimal WASM file size?
**A**: SECONDARY - fast compilation comes first, then code size

**Q**: Should we support deprecated D features for compatibility?
**A**: NO - we're building a modern subset, not maintaining legacy

## Success Metrics

### 📊 **Quantitative Targets**
- **Compilation Speed**: < 500ms for 1000 lines of D code
- **Code Quality**: 90%+ test coverage, zero known crashes  
- **Generated Code**: Within 25% of hand-optimized WASM size
- **Developer Experience**: 95% of error messages include helpful suggestions

### 🎯 **Qualitative Goals**
- **Simplicity**: Any contributor can understand the entire compiler pipeline
- **Clarity**: Code reads like the design documents describe
- **Reliability**: Developers trust the compiler to always work correctly
- **Usefulness**: Real projects choose this over other D compilers for WASM

## Future Evolution

### 📈 **How to Add Features**

**MUST**: Follow this process for any feature addition:
1. **Document the use case** - what problem does this solve?
2. **Measure the cost** - compilation speed impact? complexity increase?
3. **Design the implementation** - how does it fit existing architecture?
4. **Update this document** - adjust principles if necessary
5. **Implement with tests** - comprehensive coverage required

### 🚀 **Natural Growth Path**

Features we might add later (in priority order):
1. **Enhanced CTFE** - more compile-time computation capabilities
2. **Simple Templates** - basic generic functions without constraints
3. **Module Support** - multi-file compilation
4. **Limited Threading** - WASM threads for specific use cases

**MUST NOT**: Add these without proven demand and clear implementation plan

## Contributor Guidance

### 👥 **For Human Contributors**
- Read this document first - it's the project's constitution
- Ask questions if anything conflicts with these principles  
- Challenge these principles if you have data showing they're wrong
- Focus on one phase at a time - don't try to solve everything

### 🤖 **For AI Agents**
- Follow these rules strictly - they encode hard-won project wisdom
- When in doubt, choose the simpler solution
- Always explain decisions in terms of these principles
- Flag any request that violates MUST/MUST NOT constraints

---

## Mantra

**"Make D compilation as fast as D execution - through simplicity, not complexity."**

This document is living - update it as we learn, but keep the core principles intact. The goal is a compiler that developers love to use because it gets out of their way and lets them build great software quickly.

---

*Last updated: [DATE] | Version: 1.0 | Status: Foundation*