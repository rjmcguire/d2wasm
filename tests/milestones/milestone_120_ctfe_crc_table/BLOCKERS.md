# Milestone 120 Blockers

This milestone is blocked by missing static array features:

## Required Features

### 1. Static Array Index Assignment ❌
```d
int[4] t;
t[0] = 10;  // ERROR: Cannot index non-array type 'int'
```
**Status:** Not implemented - can't assign to static array elements

### 2. CTFE For Loops ✅
```d
for (int i = 1; i <= n; i++) { sum += i; }
```
**Status:** Working (tested in milestone_76)

### 3. CTFE While Loops ✅
```d
while (i <= n) { ... }
```
**Status:** Working (tested in milestone_76)

### 4. CTFE Returning Static Arrays ❓
```d
int[256] makeCrcTable() { ... }
enum crcTable = makeCrcTable();
```
**Status:** Unknown - blocked by #1

## Priority Order

1. **Add static array index assignment** (`t[0] = 10`) - main blocker
2. Add CTFE returning static arrays
3. Add static array indexing in main code (`crcTable[1]`)
