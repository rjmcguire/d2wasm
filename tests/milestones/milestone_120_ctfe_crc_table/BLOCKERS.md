# Milestone 120 Blockers

This milestone is blocked by missing CTFE features:

## Required Features

### 1. Static Array Index Assignment
```d
int[4] t;
t[0] = 10;  // ERROR: Cannot index non-array type 'int'
```
**Status:** Not implemented - static array elements can't be assigned

### 2. CTFE For Loops  
```d
int sumTo(int n) {
    int sum = 0;
    for (int i = 1; i <= n; i++) {
        sum += i;
    }
    return sum;
}
enum result = sumTo(10);  // Returns 10, should be 55
```
**Status:** Broken - loop only executes once

### 3. CTFE While Loops
```d
while (i <= n) { ... }  // Infinite loop in CTFE
```
**Status:** Broken - causes infinite loop

### 4. CTFE Returning Arrays
```d
int[256] makeCrcTable() { ... }
enum crcTable = makeCrcTable();  // Stores int, not array
```
**Status:** Not implemented - arrays from CTFE not handled

## Priority Order

1. Fix CTFE for loops (most blocking)
2. Fix CTFE while loops
3. Add static array index assignment
4. Add CTFE array return values
