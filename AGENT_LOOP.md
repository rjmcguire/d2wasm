# Agent Development Loop

Automated test-driven development with AI agents.

## Quick Start

### Check current status
```bash
./test_runner.sh
```

### Get next task for an agent
```bash
./get_next_task.sh
```

Returns:
- Exit 0 + "ALL_TESTS_PASS" → Done!
- Exit 2 + task prompt → Spawn an agent with this prompt

### Full loop (with external orchestration)
```bash
./agent_loop.sh              # Run until all pass or max iterations
./agent_loop.sh --dry-run    # Preview without spawning
./agent_loop.sh --max-iterations 10
```

## From OpenClaw Chat

To run the development loop from within an OpenClaw chat session:

### Step 1: Get the next task
```
Run ~/projects/d-to-wasm-compiler/get_next_task.sh
```

### Step 2: If there's a failing test, spawn an agent
Use `sessions_spawn` with the task output as the prompt.

### Step 3: Wait for completion, repeat
When the agent completes, run get_next_task.sh again.

### One-liner for the chat agent
```
Check ~/projects/d-to-wasm-compiler/get_next_task.sh output.
If ALL_TESTS_PASS → we're done.
Otherwise, spawn a sub-agent with the task, wait for completion, repeat.
```

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│  1. Run test_runner.sh                                      │
│  2. If all pass → Done                                      │
│  3. get_next_task.sh extracts:                              │
│     - Failing test name                                     │
│     - Test code (test.d)                                    │
│     - Expected vs actual output                             │
│     - Generated WAT (if available)                          │
│  4. Builds structured prompt with:                          │
│     - Context about the project                             │
│     - Instructions for fixing                               │
│     - Anti-overfitting principles                           │
│  5. Spawn agent with prompt                                 │
│  6. Agent fixes the test                                    │
│  7. Go to step 1                                            │
└─────────────────────────────────────────────────────────────┘
```

## Files

| File | Purpose |
|------|---------|
| `test_runner.sh` | Runs milestone tests, stops at first failure |
| `get_next_task.sh` | Generates agent prompt for next failing test |
| `agent_loop.sh` | Full orchestration script (for external use) |
| `DEVELOPMENT.md` | Development ethos and principles |
| `tests/milestones/` | The milestone test cases |

## Anti-Overfitting

The prompts include explicit instructions:
- No hardcoding test values
- Fix must be general
- Test with variants after fixing
- Check DEVELOPMENT.md for full guidelines

If an agent produces an overfit solution, the next milestone will likely fail, forcing a proper fix.

## Milestones

| # | Test | Status |
|---|------|--------|
| 01 | empty_module | Passing tests = ✅ |
| 02 | return_constant | |
| 03 | parameters | |
| 04 | arithmetic | |
| 05 | if_else | |
| 06 | loop | ← Current target |
| 07 | function_call | |
| 08 | ctfe_basic | Needs --ctfe-eval flag |
| 09 | ctfe_error | Needs source mapping |
| 10 | string_constant | Needs data section |
| 11 | ctfe_writeln | Needs WASI + __writeln |

Run `./test_runner.sh` to see current progress.
