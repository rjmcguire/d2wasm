/**
 * Simulates different dispatch mechanisms to understand performance.
 * 
 * This doesn't use actual stencils but simulates the behavior:
 * - vtable: 2 memory loads + indirect call
 * - chain: N comparisons + conditional jumps + direct call
 * 
 * We use D code that compiles to similar instruction patterns.
 */
module simulate_dispatch;

import std.stdio;
import std.datetime.stopwatch;
import std.random;

// Number of types to test
enum MAX_TYPES = 64;

// Simulated object with typeId
struct Obj {
    uint typeId;
    // In real impl, vtable pointer would be here
}

// Simulated method implementations (all do the same thing)
pragma(inline, false)
int method0() { return 0; }
pragma(inline, false)
int method1() { return 1; }
pragma(inline, false)
int method2() { return 2; }
pragma(inline, false)
int method3() { return 3; }
pragma(inline, false)
int method4() { return 4; }
pragma(inline, false)
int method5() { return 5; }
pragma(inline, false)
int method6() { return 6; }
pragma(inline, false)
int method7() { return 7; }

// More methods for larger type counts
pragma(inline, false) int method8() { return 8; }
pragma(inline, false) int method9() { return 9; }
pragma(inline, false) int method10() { return 10; }
pragma(inline, false) int method11() { return 11; }
pragma(inline, false) int method12() { return 12; }
pragma(inline, false) int method13() { return 13; }
pragma(inline, false) int method14() { return 14; }
pragma(inline, false) int method15() { return 15; }

// Vtable simulation - array of function pointers
alias MethodPtr = int function();
__gshared MethodPtr[MAX_TYPES] vtable;
__gshared MethodPtr*[MAX_TYPES] objectVtables;  // Per-"class" vtable pointers

shared static this() {
    // Initialize vtables
    vtable[0] = &method0;
    vtable[1] = &method1;
    vtable[2] = &method2;
    vtable[3] = &method3;
    vtable[4] = &method4;
    vtable[5] = &method5;
    vtable[6] = &method6;
    vtable[7] = &method7;
    vtable[8] = &method8;
    vtable[9] = &method9;
    vtable[10] = &method10;
    vtable[11] = &method11;
    vtable[12] = &method12;
    vtable[13] = &method13;
    vtable[14] = &method14;
    vtable[15] = &method15;
    // Rest default to method0
    for (int i = 16; i < MAX_TYPES; i++) {
        vtable[i] = &method0;
    }
    
    // Each "class" points to its slot in the vtable
    for (int i = 0; i < MAX_TYPES; i++) {
        objectVtables[i] = &vtable[i];
    }
}

// Vtable dispatch: load vtable ptr, load method ptr, call
pragma(inline, false)
int dispatchVtable(Obj* obj) {
    auto vt = objectVtables[obj.typeId];  // Load vtable pointer
    auto method = *vt;                      // Load method pointer
    return method();                        // Indirect call
}

// Chain dispatch with 4 types
pragma(inline, false)
int dispatchChain4(Obj* obj) {
    uint tid = obj.typeId;
    if (tid == 0) return method0();
    if (tid == 1) return method1();
    if (tid == 2) return method2();
    if (tid == 3) return method3();
    return -1;  // Trap
}

// Chain dispatch with 8 types
pragma(inline, false)
int dispatchChain8(Obj* obj) {
    uint tid = obj.typeId;
    if (tid == 0) return method0();
    if (tid == 1) return method1();
    if (tid == 2) return method2();
    if (tid == 3) return method3();
    if (tid == 4) return method4();
    if (tid == 5) return method5();
    if (tid == 6) return method6();
    if (tid == 7) return method7();
    return -1;
}

// Chain dispatch with 16 types
pragma(inline, false)
int dispatchChain16(Obj* obj) {
    uint tid = obj.typeId;
    if (tid == 0) return method0();
    if (tid == 1) return method1();
    if (tid == 2) return method2();
    if (tid == 3) return method3();
    if (tid == 4) return method4();
    if (tid == 5) return method5();
    if (tid == 6) return method6();
    if (tid == 7) return method7();
    if (tid == 8) return method8();
    if (tid == 9) return method9();
    if (tid == 10) return method10();
    if (tid == 11) return method11();
    if (tid == 12) return method12();
    if (tid == 13) return method13();
    if (tid == 14) return method14();
    if (tid == 15) return method15();
    return -1;
}

// Hybrid: chain for common types, vtable fallback
pragma(inline, false)
int dispatchHybrid8(Obj* obj) {
    uint tid = obj.typeId;
    // Fast path: check common types
    if (tid == 0) return method0();
    if (tid == 1) return method1();
    if (tid == 2) return method2();
    if (tid == 3) return method3();
    // Fallback to vtable for uncommon types
    auto vt = objectVtables[tid];
    return (*vt)();
}

struct BenchResult {
    string name;
    long iterations;
    Duration elapsed;
    double nsPerOp;
    int checksum;
}

BenchResult bench(string name, int function(Obj*) dispatch, Obj[] objects, long iterations) {
    int sum = 0;
    auto sw = StopWatch(AutoStart.yes);
    
    for (long i = 0; i < iterations; i++) {
        sum += dispatch(&objects[i % objects.length]);
    }
    
    sw.stop();
    double nsPerOp = cast(double)sw.peek().total!"nsecs" / iterations;
    
    return BenchResult(name, iterations, sw.peek(), nsPerOp, sum);
}

void printResults(BenchResult[] results) {
    writeln();
    writefln("%-25s %10s %10s", "Dispatch", "ns/op", "vs vtable");
    writeln("--------------------------------------------------");
    
    double vtableNs = 0;
    foreach (r; results) {
        if (r.name == "vtable") vtableNs = r.nsPerOp;
    }
    
    foreach (r; results) {
        double ratio = vtableNs > 0 ? r.nsPerOp / vtableNs : 0;
        writefln("%-25s %10.2f %10.2fx", r.name, r.nsPerOp, ratio);
    }
}

void main() {
    enum ITERATIONS = 50_000_000;
    enum POOL_SIZE = 10_000;
    
    auto rng = Random(42);
    
    writeln("=== Dispatch Mechanism Simulation ===");
    writeln();
    
    // Test 1: Monomorphic (all type 0)
    {
        writeln("--- Monomorphic (all type 0) ---");
        Obj[] objs;
        foreach (_; 0 .. POOL_SIZE) {
            objs ~= Obj(0);
        }
        
        BenchResult[] results;
        results ~= bench("vtable", &dispatchVtable, objs, ITERATIONS);
        results ~= bench("chain4", &dispatchChain4, objs, ITERATIONS);
        results ~= bench("chain8", &dispatchChain8, objs, ITERATIONS);
        results ~= bench("chain16", &dispatchChain16, objs, ITERATIONS);
        results ~= bench("hybrid8", &dispatchHybrid8, objs, ITERATIONS);
        printResults(results);
    }
    
    // Test 2: 4 types uniform
    {
        writeln();
        writeln("--- 4 types uniform ---");
        Obj[] objs;
        foreach (i; 0 .. POOL_SIZE) {
            objs ~= Obj(i % 4);
        }
        
        BenchResult[] results;
        results ~= bench("vtable", &dispatchVtable, objs, ITERATIONS);
        results ~= bench("chain4", &dispatchChain4, objs, ITERATIONS);
        results ~= bench("chain8", &dispatchChain8, objs, ITERATIONS);
        results ~= bench("hybrid8", &dispatchHybrid8, objs, ITERATIONS);
        printResults(results);
    }
    
    // Test 3: 8 types uniform
    {
        writeln();
        writeln("--- 8 types uniform ---");
        Obj[] objs;
        foreach (i; 0 .. POOL_SIZE) {
            objs ~= Obj(i % 8);
        }
        
        BenchResult[] results;
        results ~= bench("vtable", &dispatchVtable, objs, ITERATIONS);
        results ~= bench("chain8", &dispatchChain8, objs, ITERATIONS);
        results ~= bench("chain16", &dispatchChain16, objs, ITERATIONS);
        results ~= bench("hybrid8", &dispatchHybrid8, objs, ITERATIONS);
        printResults(results);
    }
    
    // Test 4: 16 types uniform
    {
        writeln();
        writeln("--- 16 types uniform ---");
        Obj[] objs;
        foreach (i; 0 .. POOL_SIZE) {
            objs ~= Obj(i % 16);
        }
        
        BenchResult[] results;
        results ~= bench("vtable", &dispatchVtable, objs, ITERATIONS);
        results ~= bench("chain16", &dispatchChain16, objs, ITERATIONS);
        results ~= bench("hybrid8", &dispatchHybrid8, objs, ITERATIONS);
        printResults(results);
    }
    
    // Test 5: Skewed (90% type 0)
    {
        writeln();
        writeln("--- Skewed 90% type 0, 10% random(0-15) ---");
        Obj[] objs;
        foreach (_; 0 .. POOL_SIZE) {
            if (uniform(0, 100, rng) < 90) {
                objs ~= Obj(0);
            } else {
                objs ~= Obj(uniform(0, 16, rng));
            }
        }
        
        BenchResult[] results;
        results ~= bench("vtable", &dispatchVtable, objs, ITERATIONS);
        results ~= bench("chain16", &dispatchChain16, objs, ITERATIONS);
        results ~= bench("hybrid8", &dispatchHybrid8, objs, ITERATIONS);
        printResults(results);
    }
    
    // Test 6: Worst case for chain (always last type)
    {
        writeln();
        writeln("--- Worst case: always type 15 (chain walks all) ---");
        Obj[] objs;
        foreach (_; 0 .. POOL_SIZE) {
            objs ~= Obj(15);
        }
        
        BenchResult[] results;
        results ~= bench("vtable", &dispatchVtable, objs, ITERATIONS);
        results ~= bench("chain16", &dispatchChain16, objs, ITERATIONS);
        results ~= bench("hybrid8", &dispatchHybrid8, objs, ITERATIONS);
        printResults(results);
    }
    
    writeln();
    writeln("Done.");
}
