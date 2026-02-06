# CTFE Lookup Table Demo

Demonstrates D's compile-time function evaluation (CTFE) to generate a CRC32 lookup table.

The 256-entry table is computed **at compile time** and embedded directly into the WASM binary.
Zero runtime cost for table generation!

## Build

```bash
cd ~/projects/d-to-wasm-compiler
./d2wasm demos/ctfe_lookup_table/crc32.d -o demos/ctfe_lookup_table/crc32.wasm
```

## What This Demonstrates

1. **Static arrays** (`int[256]`)
2. **CTFE loops** (nested for loops at compile time)
3. **Bitwise operations** (shifts, XOR, AND)
4. **Enum initialization** from CTFE function

## Expected Results

- `crcTable[0]` = 0
- `crcTable[1]` = 0x77073096 (1996959894)
- `crcTable[255]` = 0x2D02EF8D

## Status

- [ ] Static array declarations (`int[256]`)
- [ ] For loops in CTFE
- [ ] Bitwise operators (>>, ^, &) in CTFE
- [ ] Array indexing in CTFE
- [ ] Enum initialized from CTFE function returning array
