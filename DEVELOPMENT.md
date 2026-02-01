# Development Ethos

*How we build this compiler.*

---

## Core Philosophy

### No Overfitting

**Tests are examples, not the specification.**

The goal is a *general compiler* that converts any valid D source into working WASM. The tests are representative samples that exercise capabilities. Passing a test by:

- Hardcoding expected outputs
- Pattern-matching on specific test inputs
- Special-casing function names or values
- Detecting "this is test X" and returning the right answer

...is not progress. It's cheating. It will fail on real user code.

**The implementation must be general:**

```
❌ if (funcName == "add" && args == [2,3]) return 5;
✅ Parse function → Build AST → Type check → Emit WASM → Execute
```

**How we enforce this:**

1. **Varied test inputs** — same capability tested with different values
2. **Generalization checks** — after passing a test, try variants manually
3. **Code review for hardcoding** — any literal from test.d in implementation is suspicious
4. **Property-based thinking** — "for all valid inputs X, property Y holds"

**Red flags in implementation:**

- String literals that match test file contents
- Magic numbers from test cases
- `if` statements checking specific function names
- Logic that only makes sense for the test, not general code

**The question to ask:** "Would this work for code I haven't seen yet?"

### Tests Lead, Implementation Follows

We don't implement features and then write tests. We write the test first — the simplest test that exercises the next capability we need — and then implement exactly what's required to pass it.

The test suite is a roadmap. Each failing test is a signpost saying "implement this next."

### Incremental Milestones

Every feature is decomposed into the smallest testable increment:

```
❌ "Implement CTFE"                    — too big
✅ "CTFE can evaluate 2 + 3"          — testable
✅ "CTFE can call a function"         — testable  
✅ "CTFE can output a string"         — testable
```

Big features emerge from small, validated steps.

### The Development Loop

```
┌─────────────────────────────────────────────┐
│  1. Run test suite                          │
│  2. Find first failing test                 │
│  3. Implement minimum to pass it            │
│  4. Run tests again                         │
│  5. Pass? → Commit, next test.              │
│     Fail? → Read error, adjust.             │
│  6. Repeat until all tests pass.            │
└─────────────────────────────────────────────┘
```

This loop works for humans. It also works for agents. The test suite provides the feedback signal; the implementation provides the response.

### Errors Are Features

When we hit a boundary — something we don't support yet — the error message is a first-class output:

```
internal: template not found for construct
  construct: for_loop
  index_type: i128
  
  --> src/example.d:42:5

hint: i128 loops not yet implemented
```

This error is useful for:
- **The developer**: knows exactly what's missing
- **The user**: gets a clear explanation, not a crash
- **The agent**: can parse this and decide what to implement next
- **Prioritization**: error frequency shows what to build next

Never fail silently. Never produce wrong output. Fail loudly with actionable information.

### Agent-Friendly Development

The codebase should be navigable by an agent:
- Clear file organization
- Tests with obvious pass/fail criteria
- Error messages that explain what's needed
- Documentation in `notes/` that captures decisions

An agent should be able to:
1. Read a failing test
2. Understand what's missing
3. Find where to implement it
4. Make the change
5. Verify it passes

### Validation via External Tools

We don't trust only ourselves. Every output is validated by external tools:

| Output | Validator | What it proves |
|--------|-----------|----------------|
| Binary WASM | wasm3 execution | Functionally correct |
| Binary WASM | wasm2wat decompile | Structurally valid |
| Error messages | Human review | Actually helpful |

If wasm3 runs it and wasm2wat can decompile it, we know our emission is correct.

---

## Test Organization

### Directory Structure

```
tests/
├── milestone_01_empty_module/
│   ├── test.d
│   ├── expected.txt
│   └── config.json
├── milestone_02_return_constant/
│   ├── test.d
│   ├── expected.txt
│   └── config.json
├── ...
└── milestone_NN_hello_world/
    ├── test.d
    ├── expected.txt
    └── config.json
```

Tests are numbered. Order matters. Each test builds on previous capabilities.

### Test Configuration

```json
{
  "name": "return_constant",
  "description": "Function that returns a constant integer",
  "type": "ctfe_eval",
  "entry": "answer",
  "expected_value": 42
}
```

Types:
- `compile_only` — just needs to produce valid WASM
- `wasm_exec` — run in wasm3, check return value
- `ctfe_eval` — evaluate at compile time, check result
- `ctfe_output` — CTFE produces stdout output
- `compile_error` — should fail with specific error

### What a Test Provides

Each test gives the development loop:

1. **Input**: D source code
2. **Expected output**: value, stdout, or error message
3. **Validation method**: how to check success
4. **Context**: what capability this exercises

---

## The Milestone Chain

From zero to `__writeln("hello world")`:

| # | Milestone | Capability Unlocked |
|---|-----------|---------------------|
| 01 | Empty valid module | Binary emission works |
| 02 | Return constant | Function bodies, i32.const |
| 03 | Parameters | local.get, function signatures |
| 04 | Arithmetic | Binary operations |
| 05 | If/else | Control flow, comparisons |
| 06 | Loops | Structured control, br/br_if |
| 07 | CTFE detection | Compile-time evaluation trigger |
| 08 | CTFE errors | Stack traces, source mapping |
| 09 | String constants | Data section, memory |
| 10 | WASI integration | fd_write import |
| 11 | __writeln | CTFE builtin with output |

Each milestone has one or more tests. Pass all tests for milestone N before starting N+1.

---

## How to Contribute

### Adding a Feature

1. Write the test first (in next available milestone slot)
2. Run tests — your new test should fail
3. Implement until it passes
4. **Generalization check** — manually try variants:
   - Different values (not just 2+3, also 100+200, -5+10)
   - Different names (not just `add`, also `sum`, `foo`)
   - Edge cases (0, negative, max int)
5. Run full test suite — nothing should regress
6. Commit with message: `milestone_NN: description`

### Generalization Verification

After implementing a feature, ask:

| Question | If No → Problem |
|----------|-----------------|
| Would this work with different variable names? | Hardcoded names |
| Would this work with different numeric values? | Hardcoded constants |
| Would this work with the arguments in different order? | Position-dependent hack |
| Would this work in a different file? | Path/filename dependency |
| Would this work if I added unrelated code around it? | Fragile parsing |

**Quick generalization test:**
```bash
# After passing milestone_04_arithmetic (add 2+3=5), try:
echo "int foo(int x, int y) { return x + y; }" > /tmp/test.d
./d2wasm /tmp/test.d -o /tmp/test.wasm
wasm3 --func foo /tmp/test.wasm 100 200  # Should output 300
```

If it doesn't work, the implementation is overfit to the test.

### Fixing a Bug

1. Write a test that reproduces the bug
2. Run tests — new test should fail
3. Fix the bug
4. Run tests — all should pass
5. Commit with message: `fix: description (fixes #issue)`

### Improving Error Messages

Error messages are features. If an error is confusing:

1. Add a test case that triggers it
2. Update the error message
3. Verify the test's `expected.txt` matches new message
4. Commit with message: `errors: improve message for X`

---

## Commands

```bash
# Run all tests
./test_runner.sh

# Run specific milestone
./test_runner.sh milestone_05

# Run with verbose output (shows agent-friendly context on failure)
./test_runner.sh --verbose

# Run in agent mode (machine-parseable output)
./test_runner.sh --agent-mode

# Run with generalization variants (tests variants.json if present)
./test_runner.sh --variants
```

## Test Variants

Each milestone can have a `variants.json` file with additional test cases:

```json
{
  "variants": [
    {"name": "large_values", "args": ["1000", "2000"], "expected": "3000"},
    {"name": "negative", "args": ["-5", "10"], "expected": "5"}
  ]
}
```

The main test uses simple, readable values. Variants verify generalization.
If the main test passes but variants fail, the implementation is overfit.

---

## Principles Summary

1. **Tests first** — they define what we're building
2. **Small steps** — each test is one capability
3. **Errors matter** — they're the feedback signal
4. **External validation** — don't trust only ourselves
5. **Agent-friendly** — navigable, parseable, actionable

The goal is not just a working compiler. The goal is a *development process* that reliably produces a working compiler, whether driven by humans, agents, or both.
