# CTFE Time-Travel Debugger

*Parked idea — revisit if CTFE debugging becomes painful.*

## Core Concept

Use append-only columnar storage (Arrow-style) during CTFE evaluation. Every value mutation is an append, so the full history is preserved. "Time travel" is just reading different offsets.

## Why CTFE is a Good Fit

- **Deterministic** — no need to record non-determinism
- **Terminates** — bounded execution, bounded storage
- **No side effects** — the log IS the complete execution record
- **No threads** — linear timeline, no interleaving

## Data Model

```
Column<T> {
    values:     Vec<T>,           // append-only
    timestamps: Vec<LogicalTime>, // when written
}

Variable {
    name:       string,
    column_id:  u32,
    birth_time: LogicalTime,
    death_time: Option<LogicalTime>,
}

Event {
    time:       LogicalTime,
    kind:       EventKind,
    result:     ColumnRef,
    inputs:     Vec<ColumnRef>,   // dependency tracking
    source_loc: SourceLocation,
}
```

## Key Insight: Provenance for Free

Because events record their inputs, you get automatic causal tracing:
- "Why is C = 'hello world'?"
- → concat at T3 with inputs from col[0], col[1]
- → col[0] written at T1 from literal at line 1
- → Full dependency graph

## Storage

Maps directly to Arrow IPC format. Could:
- Write `.arrow` file alongside binary
- Query with DuckDB/DataFusion
- Embed in WASM as custom section (auditable builds)

## Debug Modes (Future)

```
dmd -ctfe-log=full source.d     # Record everything
dmd -ctfe-log=errors source.d   # Only on CTFE failure
dmd -ctfe-log=none source.d     # Production default
```

## Implementation Cost

- Adds complexity to CTFE evaluator
- Requires Arrow serialization infrastructure
- Requires viewer/query tooling
- **Not needed until CTFE bugs become hard to diagnose**

## Related: Living Data in WASM

The broader idea of putting Arrow-compatible layouts directly in the WASM data section. String arrays as actual Arrow StringArrays. Makes compiler output interoperable with Arrow tooling.

See also: the "data section vs manifest" discussion — we chose to put String structs directly in data section alongside bytes. Same philosophy: data that's already in its working form at load time.

---

*Filed 2026-02-02. Revisit when CTFE complexity warrants it.*
