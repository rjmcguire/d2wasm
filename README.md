# D-to-WASM Compiler Project

A focused, high-performance D language compiler targeting WebAssembly, emphasizing simplicity and predictability by excluding complex runtime features.

## 🎯 Project Vision

Build a production-ready D-to-WASM compiler in 6 months that supports a powerful subset of D language features while maintaining:
- **Fast compilation times** (< 1 second for 10k lines)
- **Predictable performance** (manual memory management)
- **Clear semantics** (no hidden runtime complexity)
- **Excellent developer experience** (helpful errors, IDE integration)

## 🚀 Key Features

### ✅ Supported D Language Features
- Functions with overloading and CTFE
- Structs and classes with inheritance
- Interfaces and virtual dispatch
- Manual memory management (no GC)
- Arrays (static and dynamic)
- Enums, unions, and operator overloading
- Function pointers and delegates
- Contracts and attributes (@safe, @pure, etc.)
- Control flow (if, while, for, foreach, switch)

### 🚫 Deliberately Excluded Features
- Templates and generics (use function overloading instead)
- Garbage collection (manual memory management only)
- Threading and concurrency (single-threaded model)
- Module system (single compilation unit)
- String mixins (too complex for initial version)

## 📁 Project Structure

```
d-to-wasm-compiler/
├── README.md                    # This file
├── DESIGN_OVERVIEW.md          # High-level architecture and vision
├── TECHNICAL_ARCHITECTURE.md   # Detailed implementation design
├── IMPLEMENTATION_PLAN.md      # 6-month development roadmap
├── TREE_SITTER_GRAMMAR.md     # Tree-sitter grammar specification
├── src/                        # Source code (to be created)
├── grammar/                    # Tree-sitter grammar files
├── runtime/                    # WASM runtime helpers
├── tests/                      # Comprehensive test suite
└── examples/                   # Example D programs
```

## 📋 Quick Start Roadmap

### Phase 1: Foundation (Weeks 1-8)
- [x] ✅ **Design Complete** - All architectural documents created
- [ ] 🔄 **Setup Project Structure** - Repository, build system, CI/CD
- [ ] 🔄 **Tree-sitter Grammar** - Complete D subset grammar
- [ ] 🔄 **Basic Compiler Pipeline** - Parser → AST → Simple codegen
- [ ] 🔄 **Minimal WASM Output** - Functions, control flow, arithmetic

**Success Criteria**: Compile simple functions like fibonacci to working WASM

### Phase 2: Data Structures (Weeks 9-12)
- [ ] 🔄 **Struct Support** - Memory layout, field access
- [ ] 🔄 **Class Foundations** - Objects, constructors, methods
- [ ] 🔄 **Array Implementation** - Static and dynamic arrays
- [ ] 🔄 **Memory Management** - malloc/free integration

**Success Criteria**: Object-oriented code with arrays compiles and runs

### Phase 3: Advanced Features (Weeks 13-20)
- [ ] 🔄 **Inheritance** - Single inheritance with virtual methods
- [ ] 🔄 **Interfaces** - Multiple interface support with dispatch
- [ ] 🔄 **Operator Overloading** - opBinary, opIndex, etc.
- [ ] 🔄 **Function Pointers** - Delegates and indirect calls

**Success Criteria**: Complex OOP programs with interfaces work correctly

### Phase 4: Quality & Polish (Weeks 21-24)
- [ ] 🔄 **CTFE Implementation** - Compile-time function execution
- [ ] 🔄 **Contracts & Attributes** - @safe, @pure, in/out contracts
- [ ] 🔄 **Optimization** - Dead code elimination, inlining
- [ ] 🔄 **Error Handling** - Comprehensive error messages

**Success Criteria**: Production-ready compiler with excellent UX

## 🛠️ Technology Stack

- **Parser**: Tree-sitter for incremental parsing
- **Language**: D (self-hosting compiler)
- **Target**: WebAssembly (WAT/WASM output)
- **Build**: DUB package manager
- **Testing**: Built-in D unittest + integration tests
- **CI/CD**: GitHub Actions

## 📊 Success Metrics

### Performance Targets
- **Compilation Speed**: < 500ms for 1000 lines of D code
- **Generated Code Size**: Within 25% of hand-optimized WASM
- **Runtime Performance**: Within 20% of LDC native compilation

### Quality Targets
- **Test Coverage**: 90%+ compiler code coverage
- **Error Messages**: Helpful diagnostics for 95% of common errors
- **Reliability**: Zero compiler crashes on valid input

## 🔍 Design Decisions

### Why No Templates?
- **Simplicity**: Avoids compilation complexity and code bloat
- **Performance**: Predictable compilation times
- **Alternative**: Function overloading covers most template use cases

### Why No GC?
- **Deterministic**: Predictable memory usage and timing
- **WASM Friendly**: Simpler integration with WASM hosts
- **Performance**: No GC pause overhead

### Why Tree-sitter?
- **Incremental**: Only re-parse changed code sections
- **Error Recovery**: Graceful handling of syntax errors
- **IDE Integration**: Built-in syntax highlighting and LSP support

## 🚦 Getting Started

1. **Review the design documents**:
   - Start with `DESIGN_OVERVIEW.md` for the big picture
   - Read `TECHNICAL_ARCHITECTURE.md` for implementation details
   - Check `IMPLEMENTATION_PLAN.md` for detailed timeline

2. **Set up development environment**:
   ```bash
   # Install D compiler (DMD or LDC)
   curl -fsS https://dlang.org/install.sh | bash -s dmd
   
   # Install tree-sitter CLI
   npm install -g tree-sitter-cli
   
   # Clone and setup project
   git clone <repository>
   cd d-to-wasm-compiler
   dub build
   ```

3. **Start with Phase 1**:
   - Implement tree-sitter grammar from `TREE_SITTER_GRAMMAR.md`
   - Build basic AST structures
   - Create minimal WASM code generator

## 🤝 Contributing

This is a focused project with clear scope and timeline. Contributions should align with:
- The defined feature subset (no scope creep)
- Clean, well-tested code
- Performance-first mindset
- Excellent error messages

## 📚 Additional Resources

- **D Language Reference**: https://dlang.org/spec/
- **WebAssembly Specification**: https://webassembly.org/
- **Tree-sitter Documentation**: https://tree-sitter.github.io/
- **WASM Binary Toolkit**: https://github.com/WebAssembly/wabt

## 🏆 Expected Outcomes

By the end of 6 months, this project will deliver:

1. **A working D-to-WASM compiler** supporting a powerful D subset
2. **Comprehensive test suite** demonstrating correctness
3. **Performance benchmarks** showing competitive code generation
4. **Developer tools** including IDE integration and helpful errors
5. **Documentation** for users and future contributors

This represents a significant contribution to both the D ecosystem and WebAssembly tooling, providing a fast, predictable path from D source code to efficient WASM binaries.

---

**Status**: 📋 Design Complete - Ready to begin implementation
**Timeline**: 6 months (24 weeks)
**Team Size**: 1-2 developers
**Complexity**: Medium-High (well-scoped engineering project)