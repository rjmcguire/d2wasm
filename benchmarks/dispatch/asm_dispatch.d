/**
 * Dispatch benchmark using inline ARM64 assembly.
 * This measures the ACTUAL cost of chain dispatch without compiler interference.
 */
module asm_dispatch;

import std.stdio;
import std.datetime.stopwatch;
import std.random;

struct Obj {
    uint typeId;
    int data;
}

// Method implementations - do real work to prevent optimization
__gshared int[256] methodResults;

shared static this() {
    foreach (i; 0 .. 256) {
        methodResults[i] = i * 7 + 13;
    }
}

// Vtable-style dispatch using inline asm
// Simulates: load vtable ptr, load method ptr, call
pragma(inline, false)
int vtableDispatchAsm(Obj* obj) {
    int result;
    
    // ARM64 inline asm for vtable-style dispatch
    // x0 = obj pointer (input)
    // We'll simulate vtable lookup with array indexing
    asm {
        // Load typeId from obj (offset 0)
        "ldr w8, [%[obj]]" : : [obj] "r" (obj) : "x8";
        
        // Load from methodResults[typeId]
        // This simulates: load vtable ptr, then load method result
        "adrp x9, %[results]@PAGE" : : [results] "i" (&methodResults) : "x9";
        "add x9, x9, %[results]@PAGEOFF" : : [results] "i" (&methodResults) : "x9";
        "ldr %[res], [x9, x8, lsl #2]" : [res] "=r" (result) : : ;
    }
    
    return result + obj.data;
}

// Chain dispatch for 4 types using inline asm
pragma(inline, false)
int chainDispatch4Asm(Obj* obj) {
    int result;
    
    asm {
        // Load typeId
        "ldr w8, [%[obj]]" : : [obj] "r" (obj) : "x8";
        
        // Compare chain: 4 types
        "cmp w8, #0\n"
        "b.eq 1f\n"
        "cmp w8, #1\n"
        "b.eq 2f\n"
        "cmp w8, #2\n"
        "b.eq 3f\n"
        "cmp w8, #3\n"
        "b.eq 4f\n"
        "mov w8, #-1\n"  // fallback
        "b 5f\n"
        
        "1: mov w8, #13\n"     // result for type 0
        "b 5f\n"
        "2: mov w8, #20\n"     // result for type 1
        "b 5f\n"
        "3: mov w8, #27\n"     // result for type 2
        "b 5f\n"
        "4: mov w8, #34\n"     // result for type 3
        "5: mov %[res], w8" : [res] "=r" (result) : : "x8";
    }
    
    return result + obj.data;
}

// Chain dispatch for 8 types
pragma(inline, false)
int chainDispatch8Asm(Obj* obj) {
    int result;
    
    asm {
        "ldr w8, [%[obj]]" : : [obj] "r" (obj) : "x8";
        
        "cmp w8, #0\n"  "b.eq 10f\n"
        "cmp w8, #1\n"  "b.eq 11f\n"
        "cmp w8, #2\n"  "b.eq 12f\n"
        "cmp w8, #3\n"  "b.eq 13f\n"
        "cmp w8, #4\n"  "b.eq 14f\n"
        "cmp w8, #5\n"  "b.eq 15f\n"
        "cmp w8, #6\n"  "b.eq 16f\n"
        "cmp w8, #7\n"  "b.eq 17f\n"
        "mov w8, #-1\n"
        "b 20f\n"
        
        "10: mov w8, #13\n"  "b 20f\n"
        "11: mov w8, #20\n"  "b 20f\n"
        "12: mov w8, #27\n"  "b 20f\n"
        "13: mov w8, #34\n"  "b 20f\n"
        "14: mov w8, #41\n"  "b 20f\n"
        "15: mov w8, #48\n"  "b 20f\n"
        "16: mov w8, #55\n"  "b 20f\n"
        "17: mov w8, #62\n"
        "20: mov %[res], w8" : [res] "=r" (result) : : "x8";
    }
    
    return result + obj.data;
}

// Chain dispatch for 16 types
pragma(inline, false)
int chainDispatch16Asm(Obj* obj) {
    int result;
    
    asm {
        "ldr w8, [%[obj]]" : : [obj] "r" (obj) : "x8";
        
        "cmp w8, #0\n"   "b.eq 100f\n"
        "cmp w8, #1\n"   "b.eq 101f\n"
        "cmp w8, #2\n"   "b.eq 102f\n"
        "cmp w8, #3\n"   "b.eq 103f\n"
        "cmp w8, #4\n"   "b.eq 104f\n"
        "cmp w8, #5\n"   "b.eq 105f\n"
        "cmp w8, #6\n"   "b.eq 106f\n"
        "cmp w8, #7\n"   "b.eq 107f\n"
        "cmp w8, #8\n"   "b.eq 108f\n"
        "cmp w8, #9\n"   "b.eq 109f\n"
        "cmp w8, #10\n"  "b.eq 110f\n"
        "cmp w8, #11\n"  "b.eq 111f\n"
        "cmp w8, #12\n"  "b.eq 112f\n"
        "cmp w8, #13\n"  "b.eq 113f\n"
        "cmp w8, #14\n"  "b.eq 114f\n"
        "cmp w8, #15\n"  "b.eq 115f\n"
        "mov w8, #-1\n"
        "b 200f\n"
        
        "100: mov w8, #13\n"   "b 200f\n"
        "101: mov w8, #20\n"   "b 200f\n"
        "102: mov w8, #27\n"   "b 200f\n"
        "103: mov w8, #34\n"   "b 200f\n"
        "104: mov w8, #41\n"   "b 200f\n"
        "105: mov w8, #48\n"   "b 200f\n"
        "106: mov w8, #55\n"   "b 200f\n"
        "107: mov w8, #62\n"   "b 200f\n"
        "108: mov w8, #69\n"   "b 200f\n"
        "109: mov w8, #76\n"   "b 200f\n"
        "110: mov w8, #83\n"   "b 200f\n"
        "111: mov w8, #90\n"   "b 200f\n"
        "112: mov w8, #97\n"   "b 200f\n"
        "113: mov w8, #104\n"  "b 200f\n"
        "114: mov w8, #111\n"  "b 200f\n"
        "115: mov w8, #118\n"
        "200: mov %[res], w8" : [res] "=r" (result) : : "x8";
    }
    
    return result + obj.data;
}

// Chain dispatch for 32 types
pragma(inline, false)
int chainDispatch32Asm(Obj* obj) {
    int result;
    
    asm {
        "ldr w8, [%[obj]]" : : [obj] "r" (obj) : "x8";
        
        // First 16
        "cmp w8, #0\n"   "b.eq 300f\n"
        "cmp w8, #1\n"   "b.eq 301f\n"
        "cmp w8, #2\n"   "b.eq 302f\n"
        "cmp w8, #3\n"   "b.eq 303f\n"
        "cmp w8, #4\n"   "b.eq 304f\n"
        "cmp w8, #5\n"   "b.eq 305f\n"
        "cmp w8, #6\n"   "b.eq 306f\n"
        "cmp w8, #7\n"   "b.eq 307f\n"
        "cmp w8, #8\n"   "b.eq 308f\n"
        "cmp w8, #9\n"   "b.eq 309f\n"
        "cmp w8, #10\n"  "b.eq 310f\n"
        "cmp w8, #11\n"  "b.eq 311f\n"
        "cmp w8, #12\n"  "b.eq 312f\n"
        "cmp w8, #13\n"  "b.eq 313f\n"
        "cmp w8, #14\n"  "b.eq 314f\n"
        "cmp w8, #15\n"  "b.eq 315f\n"
        // Second 16
        "cmp w8, #16\n"  "b.eq 316f\n"
        "cmp w8, #17\n"  "b.eq 317f\n"
        "cmp w8, #18\n"  "b.eq 318f\n"
        "cmp w8, #19\n"  "b.eq 319f\n"
        "cmp w8, #20\n"  "b.eq 320f\n"
        "cmp w8, #21\n"  "b.eq 321f\n"
        "cmp w8, #22\n"  "b.eq 322f\n"
        "cmp w8, #23\n"  "b.eq 323f\n"
        "cmp w8, #24\n"  "b.eq 324f\n"
        "cmp w8, #25\n"  "b.eq 325f\n"
        "cmp w8, #26\n"  "b.eq 326f\n"
        "cmp w8, #27\n"  "b.eq 327f\n"
        "cmp w8, #28\n"  "b.eq 328f\n"
        "cmp w8, #29\n"  "b.eq 329f\n"
        "cmp w8, #30\n"  "b.eq 330f\n"
        "cmp w8, #31\n"  "b.eq 331f\n"
        "mov w8, #-1\n"
        "b 400f\n"
        
        "300: mov w8, #13\n"   "b 400f\n"
        "301: mov w8, #20\n"   "b 400f\n"
        "302: mov w8, #27\n"   "b 400f\n"
        "303: mov w8, #34\n"   "b 400f\n"
        "304: mov w8, #41\n"   "b 400f\n"
        "305: mov w8, #48\n"   "b 400f\n"
        "306: mov w8, #55\n"   "b 400f\n"
        "307: mov w8, #62\n"   "b 400f\n"
        "308: mov w8, #69\n"   "b 400f\n"
        "309: mov w8, #76\n"   "b 400f\n"
        "310: mov w8, #83\n"   "b 400f\n"
        "311: mov w8, #90\n"   "b 400f\n"
        "312: mov w8, #97\n"   "b 400f\n"
        "313: mov w8, #104\n"  "b 400f\n"
        "314: mov w8, #111\n"  "b 400f\n"
        "315: mov w8, #118\n"  "b 400f\n"
        "316: mov w8, #125\n"  "b 400f\n"
        "317: mov w8, #132\n"  "b 400f\n"
        "318: mov w8, #139\n"  "b 400f\n"
        "319: mov w8, #146\n"  "b 400f\n"
        "320: mov w8, #153\n"  "b 400f\n"
        "321: mov w8, #160\n"  "b 400f\n"
        "322: mov w8, #167\n"  "b 400f\n"
        "323: mov w8, #174\n"  "b 400f\n"
        "324: mov w8, #181\n"  "b 400f\n"
        "325: mov w8, #188\n"  "b 400f\n"
        "326: mov w8, #195\n"  "b 400f\n"
        "327: mov w8, #202\n"  "b 400f\n"
        "328: mov w8, #209\n"  "b 400f\n"
        "329: mov w8, #216\n"  "b 400f\n"
        "330: mov w8, #223\n"  "b 400f\n"
        "331: mov w8, #230\n"
        "400: mov %[res], w8" : [res] "=r" (result) : : "x8";
    }
    
    return result + obj.data;
}

struct Result {
    int types;
    string scenario;
    double vtableNs;
    double chainNs;
    double ratio;
}

void printResult(Result r) {
    string winner = r.ratio < 1 ? "CHAIN" : "VTABLE";
    double factor = r.ratio < 1 ? 1.0/r.ratio : r.ratio;
    string marker = factor > 7.0 ? " <<< >7x!" : "";
    
    writefln("%-12s %3d types | vtable: %6.2f ns | chain: %6.2f ns | ratio: %5.2fx | %s%s",
        r.scenario, r.types, r.vtableNs, r.chainNs, r.ratio, winner, marker);
}

void main() {
    enum ITERATIONS = 50_000_000;
    enum POOL_SIZE = 10_000;
    
    writeln("=== ASM Dispatch Benchmark (ARM64) ===");
    writeln("Measuring actual instruction costs without compiler interference");
    writeln();
    
    alias ChainFn = int function(Obj*);
    
    struct TestCase {
        int types;
        ChainFn chainFn;
    }
    
    TestCase[] tests = [
        TestCase(4, &chainDispatch4Asm),
        TestCase(8, &chainDispatch8Asm),
        TestCase(16, &chainDispatch16Asm),
        TestCase(32, &chainDispatch32Asm),
    ];
    
    // Test: Uniform distribution
    writeln("--- Uniform Distribution ---");
    foreach (test; tests) {
        Obj[] objs;
        foreach (i; 0 .. POOL_SIZE) {
            objs ~= Obj(i % test.types, i);
        }
        
        // Vtable
        int sum1 = 0;
        auto sw1 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum1 += vtableDispatchAsm(&objs[i % POOL_SIZE]);
        }
        sw1.stop();
        double vtableNs = cast(double)sw1.peek().total!"nsecs" / ITERATIONS;
        
        // Chain
        int sum2 = 0;
        auto sw2 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum2 += test.chainFn(&objs[i % POOL_SIZE]);
        }
        sw2.stop();
        double chainNs = cast(double)sw2.peek().total!"nsecs" / ITERATIONS;
        
        printResult(Result(test.types, "uniform", vtableNs, chainNs, chainNs / vtableNs));
    }
    
    // Test: Monomorphic (always type 0 - best case for chain)
    writeln();
    writeln("--- Monomorphic (always type 0) ---");
    foreach (test; tests) {
        Obj[] objs;
        foreach (i; 0 .. POOL_SIZE) {
            objs ~= Obj(0, i);
        }
        
        int sum1 = 0;
        auto sw1 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum1 += vtableDispatchAsm(&objs[i % POOL_SIZE]);
        }
        sw1.stop();
        double vtableNs = cast(double)sw1.peek().total!"nsecs" / ITERATIONS;
        
        int sum2 = 0;
        auto sw2 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum2 += test.chainFn(&objs[i % POOL_SIZE]);
        }
        sw2.stop();
        double chainNs = cast(double)sw2.peek().total!"nsecs" / ITERATIONS;
        
        printResult(Result(test.types, "mono", vtableNs, chainNs, chainNs / vtableNs));
    }
    
    // Test: Worst case (always last type)
    writeln();
    writeln("--- Worst Case (always last type) ---");
    foreach (test; tests) {
        Obj[] objs;
        foreach (i; 0 .. POOL_SIZE) {
            objs ~= Obj(test.types - 1, i);
        }
        
        int sum1 = 0;
        auto sw1 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum1 += vtableDispatchAsm(&objs[i % POOL_SIZE]);
        }
        sw1.stop();
        double vtableNs = cast(double)sw1.peek().total!"nsecs" / ITERATIONS;
        
        int sum2 = 0;
        auto sw2 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum2 += test.chainFn(&objs[i % POOL_SIZE]);
        }
        sw2.stop();
        double chainNs = cast(double)sw2.peek().total!"nsecs" / ITERATIONS;
        
        printResult(Result(test.types, "worst", vtableNs, chainNs, chainNs / vtableNs));
    }
    
    // Test: Random
    writeln();
    writeln("--- Random Distribution ---");
    auto rng = Random(42);
    foreach (test; tests) {
        Obj[] objs;
        foreach (i; 0 .. POOL_SIZE) {
            objs ~= Obj(uniform(0, test.types, rng), i);
        }
        
        int sum1 = 0;
        auto sw1 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum1 += vtableDispatchAsm(&objs[i % POOL_SIZE]);
        }
        sw1.stop();
        double vtableNs = cast(double)sw1.peek().total!"nsecs" / ITERATIONS;
        
        int sum2 = 0;
        auto sw2 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum2 += test.chainFn(&objs[i % POOL_SIZE]);
        }
        sw2.stop();
        double chainNs = cast(double)sw2.peek().total!"nsecs" / ITERATIONS;
        
        printResult(Result(test.types, "random", vtableNs, chainNs, chainNs / vtableNs));
    }
    
    writeln();
    writeln("Legend: ratio < 1 = chain wins, ratio > 1 = vtable wins");
}
