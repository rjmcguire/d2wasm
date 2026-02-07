# Dispatch Mechanism Benchmark Results

**Date:** 2026-02-07

## Goal

Evaluate chain dispatch vs vtable dispatch for virtual method calls, to determine if chain dispatch (used in some JIT inline caching implementations) could be faster than traditional vtables.

## Hypothesis

Chain dispatch (linear comparison chain) might beat vtable dispatch for small type hierarchies due to:
- Branch prediction for common types
- Avoiding indirect call overhead
- Cache locality of inline comparisons

## Methodology

Created multiple benchmarks with increasing rigor:

1. **D if-chain** — LDC optimized it away entirely (not measuring dispatch)
2. **D function pointer chain** — measured call overhead, not dispatch
3. **C with inline ARM64 assembly** — ground truth, actual instruction costs

### Test Configurations

- **Types tested:** 4, 8, 16, 32, 64
- **Distributions:** Uniform, Monomorphic (type 0), Worst case (last type), Random
- **Iterations:** 50 million per test
- **Platform:** ARM64 (Apple Silicon)

## Results (ASM Benchmark)

### Vtable Dispatch
```
Consistent ~0.95 ns regardless of type count or distribution
```

### Chain Dispatch (cmp + b.eq per type)

| Distribution | 4 types | 8 types | 16 types | 32 types | 64 types |
|--------------|---------|---------|----------|----------|----------|
| Uniform      | 1.44x   | 2.35x   | 2.71x    | 3.53x    | 6.20x    |
| Monomorphic  | 1.67x   | 1.67x   | 1.66x    | 1.65x    | 1.67x    |
| Worst case   | 1.34x   | 1.84x   | 3.15x    | 5.84x    | **11.14x** |
| Random       | **7.01x** | 5.79x | 6.37x    | 6.69x    | **8.86x** |

(Ratios are chain/vtable; >1 means vtable wins)

## Key Findings

1. **Vtable wins in ALL scenarios tested** — even with just 4 types

2. **Branch misprediction dominates chain cost** — Random distribution shows 7x slowdown even at 4 types because conditional branches mispredict

3. **Vtable is O(1) in practice** — two loads (obj→vtable, vtable→method) are faster than any chain of comparisons

4. **Monomorphic doesn't save chain** — even when always type 0, chain is 1.67x slower due to instruction overhead

5. **The >7x threshold:**
   - Worst case: hits at 64 types (11.14x)
   - Random: hits immediately at 4 types (7.01x)

## Why Chain Lost

We expected chain to benefit from branch prediction. Reality:

- **Indirect branch prediction** (vtable) is quite good on modern CPUs
- **Conditional branch misprediction** (chain) costs ~10-15 cycles per miss
- **Table lookup** is just two loads — very fast, no branching
- **Chain walks** accumulate comparison overhead even when branches predict correctly

## Why Earlier Benchmarks Were Misleading

1. **LDC optimization:** When we wrote D if-chains, LDC recognized the pattern and optimized the entire dispatch away (returned `typeId` directly). We were measuring compiler cleverness, not dispatch.

2. **Function pointer chains:** Added call overhead at each step, making chain look even worse than inline comparisons.

## Conclusions

1. **Use vtables** — they're fast, proven, O(1)

2. **Devirtualize at compile time** — when type is statically known, emit direct calls

3. **Inline caching** (runtime code patching) is the only way chain-like dispatch wins — by eliminating comparisons entirely, not by comparing faster

4. **For CTFE:** We have perfect type knowledge. Aggressive inlining + constant folding achieves devirtualization automatically (like LDC did "by accident").

## Files

Benchmark code: `benchmarks/dispatch/`
- `asm_bench.c` — ground truth ARM64 assembly benchmark
- `chain_true.d` — function pointer chain (showed O(n) scaling)
- `simulate_v3.d` — D classes vs switch
- `generate_hierarchy.d` — generates test class hierarchies
