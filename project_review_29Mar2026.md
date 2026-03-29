# D-to-WASM Compiler — Project Review

## At a Glance

| Metric | Value |
|---|---|
| Source code | **~62,000 lines** of D across 30+ files |
| Test suite | **327 tests** (268 milestones + 59 quality tests) |
| Milestones covered | `milestone_01` (empty module) → `milestone_275` (LSP workspace) |
| Backends | WASM (binary emission) + ARM64 native (copy-and-patch JIT) |
| Largest files | `native/backend.d` (8k), [emitter.d](file:///Users/klaus/projects/d-to-wasm-compiler/src/codegen/emitter.d) (4.5k), `tree_sitter_bridge.d` (4.5k), `type_checker.d` (4k) |

---

## What's Impressive

### 1. Scope and ambition
This isn't a toy compiler. You've built a **full compilation pipeline** — parsing, semantic analysis, CTFE, WASM code generation, *and* an ARM64 native backend — all in D, totaling 62k lines. That's a serious piece of engineering for what appears to be a solo/small-team project.

### 2. The dual backend strategy
Having both a WASM backend and a **copy-and-patch ARM64 JIT** is a genuinely clever design choice. Using the native backend for CTFE execution avoids interpreter overhead and shows real systems-level thinking. This is a technique used by production compilers (CPython's JIT adopted a similar approach recently).

### 3. Tree-sitter integration
Using tree-sitter as the parser frontend is pragmatic — you get incremental parsing, error recovery, and IDE support essentially for free. The bridge pattern (`tree_sitter_bridge.d`) cleanly separates the external C API from your D-native AST.

### 4. Test-driven milestone approach
327 tests organized as numbered milestones is excellent engineering discipline. Each milestone has a clear [test.d](file:///Users/klaus/projects/d-to-wasm-compiler/tests/milestones/milestone_110_persistent_code_cache/test.d) + `config.json` structure, making it easy to understand what's being tested and to reproduce failures. The 59 quality tests for error messages show you care about developer experience, not just correctness.

### 5. Comprehensive LSP server
Going from `milestone_267` through `milestone_275`, you've implemented signature help, code lens, semantic tokens, call hierarchy, type hierarchy, rename, incremental sync, code actions, and workspace support. That's a **full-featured language server** — not something most hobby compilers attempt.

### 6. ObjC interop
Milestones 258–266 show Objective-C runtime integration — class bridging, selectors, struct returns, HFA handling. This strongly suggests you're targeting macOS/iOS native apps from D via WASM/native, which is a unique and ambitious niche.

### 7. Excellent documentation
The [ARCHITECTURE.md](file:///Users/klaus/projects/d-to-wasm-compiler/ARCHITECTURE.md) is genuinely one of the best architecture docs I've seen in a project this size. The "Common Modification Scenarios" section — showing step-by-step what files to touch to add a new operator, statement, type, or CTFE intrinsic — is the kind of documentation that makes a project maintainable.

---

## Areas to Consider

### 1. File size concerns
A few files are getting large:
- [emitter.d](file:///Users/klaus/projects/d-to-wasm-compiler/src/codegen/emitter.d) — **178KB** on disk (~4,500 lines), and this is *after* you've already split expression/call/statement emission into `src/codegen/wasm/`
- `lsp_server.d` — **75KB** (~2,000 lines)
- `native/backend.d` — ~8,000 lines

These are approaching the point where navigability becomes a concern. Consider whether `lsp_server.d` could be split by LSP capability (e.g., `lsp_completion.d`, `lsp_hover.d`, `lsp_rename.d`).

### 2. README roadmap vs. reality
The README still shows Phase 1–4 items as `🔄` (in progress), but the milestone numbers tell a very different story — you're well past the "basics" and into ObjC interop and LSP features. The README undersells the project's current state significantly. Worth updating to reflect actual progress.

### 3. Deliberately excluded features — revisit?
The README says "no templates" and "no module system," but:
- Milestones `094`–`097` show template/IFTI support was added
- The architecture mentions mixins as a template alternative

This is fine — scope evolves — but the docs should be updated so newcomers get an accurate picture.

### 4. Incremental compilation
You have `src/incremental/` and `src/cache/` directories, plus milestones 101–111 covering caching and incremental compilation. It would be good to understand how mature this is — incremental compilation is notoriously hard to get right (cache invalidation, dependency tracking edge cases). The [INCREMENTAL.md](file:///Users/klaus/projects/d-to-wasm-compiler/INCREMENTAL.md) exists but at only 2.6KB, it's probably just an outline.

### 5. Error handling strategy
The architecture mentions 5 error types (`ParseError`, `MixinError`, `TypeError`, `EmitError`, `CTFEError`) but it's not obvious from the structure whether these form a proper hierarchy or are propagated consistently. In a 62k-line compiler, inconsistent error propagation can lead to crashes on malformed input or silent failures.

---

## Overall Assessment

This is a **genuinely impressive** project. The combination of:
- D self-hosting compiler → WASM
- Copy-and-patch native JIT for CTFE
- Full LSP support
- ObjC runtime bridging
- 327 milestone-driven tests
- Clean architecture with excellent docs

...puts this well above typical hobby compilers. The engineering quality is high — the code is well-organized, the testing is disciplined, and the architecture doc alone shows strong software design thinking.

If I had to summarize in one line: **you've built a serious, well-architected compiler with real-world ambitions, and you've executed on it methodically through 275+ milestones.**

The main areas for improvement are keeping the documentation in sync with reality (the README undersells it) and watching the file size growth in `emitter.d` and `lsp_server.d`.
