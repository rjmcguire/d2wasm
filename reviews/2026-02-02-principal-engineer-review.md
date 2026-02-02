# D-to-WASM Compiler Code Review

**Date:** 2026-02-02  
**Reviewer:** Principal Engineer (pedantic mode)  
**Scope:** Full codebase review focusing on defensive programming, error handling, and maintainability

## Executive Summary

This is a functional D-to-WASM compiler with working CTFE, mixin expansion, and binary WASM emission. However, I've identified several issues ranging from critical bugs to maintainability concerns. The codebase shows signs of rapid development with some technical debt accumulated.

---

## 🔴 CRITICAL Issues

### 1. Division by Zero in CTFE — `src/semantic/ctfe.d:563-593`

```d
final switch (binary.operator) {
    case BinaryExpression.Operator.Divide: return left / right;
    case BinaryExpression.Operator.Modulo: return left % right;
    // ...
}
```

**Problem:** No guard against division by zero. Same issue in `src/codegen/emitter.d:1761-1808` and `mixin_expander.d:264`.

**Fix:**
```d
case BinaryExpression.Operator.Divide:
    if (right == 0) throw new CTFEError("Division by zero in constant expression");
    return left / right;
```

---

### 2. Unchecked Shift Amounts — `src/semantic/ctfe.d:591-592`

```d
case BinaryExpression.Operator.ShiftLeft: return left << right;
case BinaryExpression.Operator.ShiftRight: return left >> right;
```

**Problem:** Shifting by negative amounts or amounts >= 64 is undefined behavior in many contexts. D itself has defined behavior, but this can produce unexpected results.

**Fix:**
```d
case BinaryExpression.Operator.ShiftLeft:
    if (right < 0 || right >= 64) throw new CTFEError("Shift amount out of range");
    return left << right;
```

---

### 3. Null Dereference in Parser — `src/parser/tree_sitter_bridge.d:133-136`

```d
for (uint i = 0; i < childCount; i++) {
    TSNode child = TreeSitterParser.getChild(root, i);
    if (!TreeSitterParser.isValid(child)) {
        writeln("Warning: Invalid child node at index ", i);
        continue;  // Continues but doesn't prevent later null access
    }
```

**Problem:** While this logs a warning, subsequent code in the same function may still try to access invalid nodes. The `continue` only skips the current iteration but doesn't guarantee safety for nested operations.

**Recommendation:** Add defensive checks at every node access point, or fail fast on invalid parse trees.

---

### 4. Type Confusion in Expression Evaluation — `src/codegen/emitter.d:1034-1040`

```d
void emitLiteral(ref Appender!(ubyte[]) out_, LiteralExpression expr) {
    if (expr.value.type == typeid(long)) {
        out_ ~= Op.i32_const;
        leb128s(out_, expr.value.get!long());  // Truncates 64-bit to 32-bit
```

**Problem:** A `long` value is being emitted as `i32_const`, which silently truncates values > INT_MAX. This could cause subtle runtime bugs.

**Fix:** Either detect overflow and emit `i64_const` for large values, or explicitly validate the range:
```d
long val = expr.value.get!long();
if (val > int.max || val < int.min) {
    throw new EmitError(format("Integer literal %d exceeds i32 range", val));
}
```

---

## 🟠 HIGH Issues

### 5. Silent Error Swallowing in Parser — `src/parser/tree_sitter_bridge.d:142-151`

```d
} catch (ParseError e) {
    writeln("Parse error in ", nodeType, ": ", e.msg);
    // Continue parsing other declarations  ← SILENT FAILURE
} catch (Exception e) {
    writeln("Unexpected error in ", nodeType, ": ", e.msg);
    // Continue parsing other declarations  ← SILENT FAILURE
}
```

**Problem:** Parse errors are logged but not reported to the caller. The compiler continues with a partial/broken AST. Users see no error exit code.

**Fix:** Accumulate errors and report them at the end, or fail immediately on first error:
```d
private ParseError[] errors;
// ... in catch block:
errors ~= e;
// ... at end of parseSourceFileNode:
if (errors.length > 0) throw new ParseError("Multiple parse errors", ...);
```

---

### 6. Missing Return Path Analysis — `src/codegen/emitter.d:865`

```d
private ubyte[] emitFunctionBody(FuncInfo f) {
    // ...
    if (f.decl.body_) {
        ctx.emitStatement(body_, f.decl.body_);
    }
    body_ ~= Op.end;
    return body_.data;
}
```

**Problem:** Non-void functions without explicit `return` statements will hit `end` opcode, which is undefined behavior for functions expecting a return value. The WASM validator may reject this, but the compiler should catch it first.

**Fix:** Add control flow analysis to verify all paths return a value.

---

### 7. Unbounded Recursion in Mixin Expansion — `src/semantic/mixin_expander.d:77-92`

```d
Declaration[] expandMixins(Declaration[] declarations) {
    // ...
    foreach (decl; declarations) {
        if (auto mixinDecl = cast(MixinDecl)decl) {
            auto expanded = expandMixin(mixinDecl);
            result ~= expanded;  // expanded can contain more mixins!
        }
        // ...
    }
}
```

**Problem:** If a mixin expands to code containing another mixin (which is valid D), and there's a cycle, this will stack overflow. No cycle detection exists.

**Fix:** Add depth tracking and cycle detection:
```d
private int expansionDepth = 0;
private enum MAX_EXPANSION_DEPTH = 100;

Declaration[] expandMixin(MixinDecl mixinDecl) {
    if (++expansionDepth > MAX_EXPANSION_DEPTH) {
        throw new MixinError("Mixin expansion depth exceeded (possible cycle)", ...);
    }
    scope(exit) expansionDepth--;
    // ...
}
```

---

### 8. Memory Layout Assumptions — `src/codegen/emitter.d:71-75` and `wasm.d`

```d
struct ArrayLiteralInfo {
    uint structOffset;   // Where the Array struct is in memory
    uint dataOffset;     // Where the character data is
    uint length;
}
```

**Problem:** The code assumes specific struct layouts (Array struct = {ptr, len, cap} at offsets 0, 4, 8). These constants appear in multiple places:

- `emitter.d:756` — `ARRAY_PTR_OFFSET`
- `emitter.d:1045` — hardcoded `i32_load` offsets

If the layout changes, it must be updated in multiple places.

**Fix:** Define constants in one place and reference them everywhere:
```d
// In codegen/wasm.d:
enum ARRAY_PTR_OFFSET = 0;
enum ARRAY_LEN_OFFSET = 4;
enum ARRAY_CAP_OFFSET = 8;
enum ARRAY_STRUCT_SIZE = 12;
```

---

### 9. Type Checker Allows Null Type Access — `src/semantic/type_checker.d:253-264`

```d
if (expr.operator >= BinaryExpression.Operator.Equal && 
    expr.operator <= BinaryExpression.Operator.GreaterEqual) {
    
    // Check for null types first
    if (!leftType) {
        throw new TypeError(
            format("Left operand has unknown type..."), expr.location
        );
    }
```

**Problem:** The null check is only done for comparison operators but not for arithmetic operators (lines 238-249). If `checkExpression` returns null for some edge case, this will crash.

**Fix:** Consolidate null checking at the start of `checkBinaryExpression`:
```d
Type leftType = checkExpression(expr.left);
Type rightType = checkExpression(expr.right);
if (!leftType || !rightType) {
    throw new TypeError("Could not determine operand types", expr.location);
}
```

---

## 🟡 MEDIUM Issues

### 10. Debug Output in Production Code — Multiple Files

**Files:** `main.d:40`, `tree_sitter_bridge.d:82`, `ctfe.d:69`, `mixin_expander.d:72`, `emitter.d` (multiple)

```d
writeln("main() started");
writeln("Parsing with tree-sitter-d...");
writeln("CTFE: Evaluating ", manifest.name);
```

**Problem:** Debug `writeln` statements are scattered throughout the codebase. This clutters output and affects performance.

**Fix:** Implement a proper logging abstraction:
```d
enum LogLevel { DEBUG, INFO, WARN, ERROR }
void log(LogLevel level, lazy string msg) {
    if (level >= currentLogLevel) writeln(msg);
}
```

Or use D's built-in `-debug` conditional compilation.

---

### 11. Inconsistent Error Handling Patterns

**Files:** `ctfe.d`, `mixin_expander.d`, `type_checker.d`

Three different error classes with inconsistent usage:
- `CTFEError` — no location field
- `MixinError` — has location field
- `TypeError` — has location field

**Fix:** Create a common base class:
```d
class CompilerError : Exception {
    SourceLocation location;
    this(string msg, SourceLocation loc) { ... }
}
class CTFEError : CompilerError { ... }
```

---

### 12. Magic Numbers in Emitter — `src/codegen/emitter.d`

```d
leb128u(body_, 2);  // align
leb128u(body_, 7);  // some offset
body_ ~= cast(ubyte)0xFC;  // memory.copy prefix
body_ ~= cast(ubyte)0x0A;  // memory.copy opcode
```

**Problem:** Opcodes and alignment values are hardcoded without explanation.

**Fix:** Define named constants:
```d
enum WasmPrefix : ubyte { BULK_MEMORY = 0xFC }
enum BulkOp : ubyte { MEMORY_COPY = 0x0A }
enum WASM_ALIGNMENT_I32 = 2;
```

---

### 13. Incomplete TODO Handling — `src/parser/tree_sitter_bridge.d:206`

```d
// TODO: Parse attributes from the tree-sitter node
string[] attributes;
```

**Problem:** Function attributes (`@safe`, `@pure`, etc.) are not parsed but the compiler silently ignores them. This could lead to incorrect WASM output if someone expects `@safe` enforcement.

**Fix:** Either implement attribute parsing or explicitly throw an error when attributes are present.

---

### 14. Copy-Paste Code in Binary Expression Evaluation

**Files:** `ctfe.d:563-593`, `emitter.d:1761-1808`, `mixin_expander.d:230-275`

The same `final switch (binary.operator)` pattern is duplicated three times with nearly identical code.

**Fix:** Extract to a shared function:
```d
// In a shared module:
long evaluateBinaryOp(BinaryExpression.Operator op, long left, long right) {
    final switch (op) { ... }
}
```

---

### 15. No Bounds Checking on Array Access — `src/codegen/emitter.d`

```d
body_ ~= Op.local_get;
leb128u(body_, 0);  // Assumes local 0 exists
```

**Problem:** Local variable indices are not validated against the actual local count.

**Fix:** Add assertions or validation:
```d
assert(localIndex < localTypes.length, "Local index out of bounds");
```

---

## 🟢 LOW Issues

### 16. Inconsistent Naming Conventions

- `body_` vs `body` (trailing underscore) — used inconsistently
- `function_` vs `func` — mixed conventions
- `params` vs `parameters` — inconsistent

**Fix:** Establish and document naming conventions.

---

### 17. Missing `scope(exit)` in Resource Management — `src/semantic/ctfe.d:174-175`

```d
auto runtime = new CTFERuntime();
scope(exit) destroy(runtime);
```

This is good! But similar patterns in other places don't use `scope(exit)`:

```d
// tree_sitter_bridge.d - parser is a class member, never explicitly destroyed
this.parser = new TreeSitterParser();
```

**Fix:** Review all resource allocations for proper cleanup.

---

### 18. Commented-Out Code — `src/main.d:245-257`

```d
/**
 * Generate placeholder WASM file
 * TODO: Replace with real WASM code generation
 */
void generateWasmPlaceholder(...) { ... }
```

**Problem:** Dead code that's no longer called (real emission is implemented).

**Fix:** Delete it.

---

### 19. AST Node `parent` Field Never Set — `src/ast/nodes.d:30`

```d
abstract class ASTNode {
    ASTNode parent;  // Never assigned anywhere in the codebase
```

**Problem:** The `parent` field exists but is never populated during parsing. Any code relying on it will get null.

**Fix:** Either populate it during parsing or remove it.

---

### 20. Variant Type Usage Could Be Safer — `src/ast/expressions.d:174`

```d
class LiteralExpression : Expression {
    Variant value;
```

**Problem:** `Variant` is flexible but type-unsafe. The code does `value.get!T()` without always checking `value.type == typeid(T)` first.

**Fix:** Either always check type before getting, or use a sum type (`SumType`) for the limited set of literal types.

---

## Structural Issues

### 21. God Class: `BinaryEmitter` — `src/codegen/emitter.d`

At 1865 lines, `BinaryEmitter` does too much:
- WASM header emission
- Type section
- Function section
- Memory management
- Data section
- Expression evaluation
- Built-in function generation

**Recommendation:** Split into smaller focused classes:
- `WasmModuleBuilder`
- `FunctionEmitter`
- `DataSectionManager`
- `TypeSectionBuilder`

---

### 22. Missing Unit Tests for Core Components

The test files focus on integration tests. There are no unit tests for:
- `CTFEEvaluator.evaluateSimpleExpression`
- `BinaryEmitter.leb128u/leb128s`
- `TypeChecker.checkTypeCompatibility`

---

## Summary by Priority

| Severity | Count | Action |
|----------|-------|--------|
| 🔴 Critical | 4 | Fix immediately — potential crashes or incorrect code |
| 🟠 High | 5 | Fix soon — affects reliability |
| 🟡 Medium | 6 | Fix in next refactor — affects maintainability |
| 🟢 Low | 5 | Fix when convenient — code hygiene |

---

## Recommended Immediate Actions

1. **Add division-by-zero guards** in all CTFE evaluation paths
2. **Fix integer truncation** in emitter (long → i32)
3. **Add mixin expansion cycle detection**
4. **Convert silent parse errors to actual failures**
5. **Consolidate null checks** in type checker
