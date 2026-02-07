/**
 * Dispatch benchmark using inline ARM64 assembly.
 * This measures the ACTUAL cost of chain dispatch without compiler interference.
 */
module asm_dispatch2;

import std.stdio;
import std.datetime.stopwatch;
import std.random;

struct Obj {
    uint typeId;
    int data;
}

// Method result lookup table
__gshared int[256] methodResults;

shared static this() {
    foreach (i; 0 .. 256) {
        methodResults[i] = i * 7 + 13;
    }
}

// Vtable-style: two loads (simulate vtable ptr + method ptr) + indirect result
pragma(inline, false)
int vtableDispatchAsm(Obj* obj) {
    int result;
    int* table = methodResults.ptr;
    
    version (AArch64) {
        asm {
            // Load typeId from obj
            "ldr w8, [%1]" ~
            // Load result from table[typeId]
            "ldr %0, [%2, w8, sxtw #2]"
            : "=r" (result)
            : "r" (obj), "r" (table)
            : "x8";
        }
    } else {
        result = methodResults[obj.typeId];
    }
    
    return result + obj.data;
}

// Chain dispatch 4 types - linear comparison chain
pragma(inline, false)
int chainDispatch4Asm(Obj* obj) {
    int result;
    
    version (AArch64) {
        asm {
            "ldr w8, [%1]\n" ~        // Load typeId
            "cmp w8, #0\n" ~
            "b.eq 1f\n" ~
            "cmp w8, #1\n" ~
            "b.eq 2f\n" ~
            "cmp w8, #2\n" ~
            "b.eq 3f\n" ~
            "cmp w8, #3\n" ~
            "b.eq 4f\n" ~
            "mov w9, #-1\n" ~
            "b 5f\n" ~
            "1: mov w9, #13\n" ~
            "b 5f\n" ~
            "2: mov w9, #20\n" ~
            "b 5f\n" ~
            "3: mov w9, #27\n" ~
            "b 5f\n" ~
            "4: mov w9, #34\n" ~
            "5: mov %0, w9"
            : "=r" (result)
            : "r" (obj)
            : "x8", "x9";
        }
    } else {
        switch (obj.typeId) {
            case 0: result = 13; break;
            case 1: result = 20; break;
            case 2: result = 27; break;
            case 3: result = 34; break;
            default: result = -1;
        }
    }
    
    return result + obj.data;
}

// Chain dispatch 8 types
pragma(inline, false)
int chainDispatch8Asm(Obj* obj) {
    int result;
    
    version (AArch64) {
        asm {
            "ldr w8, [%1]\n" ~
            "cmp w8, #0\n" ~ "b.eq 10f\n" ~
            "cmp w8, #1\n" ~ "b.eq 11f\n" ~
            "cmp w8, #2\n" ~ "b.eq 12f\n" ~
            "cmp w8, #3\n" ~ "b.eq 13f\n" ~
            "cmp w8, #4\n" ~ "b.eq 14f\n" ~
            "cmp w8, #5\n" ~ "b.eq 15f\n" ~
            "cmp w8, #6\n" ~ "b.eq 16f\n" ~
            "cmp w8, #7\n" ~ "b.eq 17f\n" ~
            "mov w9, #-1\n" ~ "b 20f\n" ~
            "10: mov w9, #13\n" ~ "b 20f\n" ~
            "11: mov w9, #20\n" ~ "b 20f\n" ~
            "12: mov w9, #27\n" ~ "b 20f\n" ~
            "13: mov w9, #34\n" ~ "b 20f\n" ~
            "14: mov w9, #41\n" ~ "b 20f\n" ~
            "15: mov w9, #48\n" ~ "b 20f\n" ~
            "16: mov w9, #55\n" ~ "b 20f\n" ~
            "17: mov w9, #62\n" ~
            "20: mov %0, w9"
            : "=r" (result)
            : "r" (obj)
            : "x8", "x9";
        }
    } else {
        result = methodResults[obj.typeId < 8 ? obj.typeId : 0];
    }
    
    return result + obj.data;
}

// Chain dispatch 16 types
pragma(inline, false)
int chainDispatch16Asm(Obj* obj) {
    int result;
    
    version (AArch64) {
        asm {
            "ldr w8, [%1]\n" ~
            "cmp w8, #0\n"  ~ "b.eq 100f\n" ~
            "cmp w8, #1\n"  ~ "b.eq 101f\n" ~
            "cmp w8, #2\n"  ~ "b.eq 102f\n" ~
            "cmp w8, #3\n"  ~ "b.eq 103f\n" ~
            "cmp w8, #4\n"  ~ "b.eq 104f\n" ~
            "cmp w8, #5\n"  ~ "b.eq 105f\n" ~
            "cmp w8, #6\n"  ~ "b.eq 106f\n" ~
            "cmp w8, #7\n"  ~ "b.eq 107f\n" ~
            "cmp w8, #8\n"  ~ "b.eq 108f\n" ~
            "cmp w8, #9\n"  ~ "b.eq 109f\n" ~
            "cmp w8, #10\n" ~ "b.eq 110f\n" ~
            "cmp w8, #11\n" ~ "b.eq 111f\n" ~
            "cmp w8, #12\n" ~ "b.eq 112f\n" ~
            "cmp w8, #13\n" ~ "b.eq 113f\n" ~
            "cmp w8, #14\n" ~ "b.eq 114f\n" ~
            "cmp w8, #15\n" ~ "b.eq 115f\n" ~
            "mov w9, #-1\n" ~ "b 200f\n" ~
            "100: mov w9, #13\n"  ~ "b 200f\n" ~
            "101: mov w9, #20\n"  ~ "b 200f\n" ~
            "102: mov w9, #27\n"  ~ "b 200f\n" ~
            "103: mov w9, #34\n"  ~ "b 200f\n" ~
            "104: mov w9, #41\n"  ~ "b 200f\n" ~
            "105: mov w9, #48\n"  ~ "b 200f\n" ~
            "106: mov w9, #55\n"  ~ "b 200f\n" ~
            "107: mov w9, #62\n"  ~ "b 200f\n" ~
            "108: mov w9, #69\n"  ~ "b 200f\n" ~
            "109: mov w9, #76\n"  ~ "b 200f\n" ~
            "110: mov w9, #83\n"  ~ "b 200f\n" ~
            "111: mov w9, #90\n"  ~ "b 200f\n" ~
            "112: mov w9, #97\n"  ~ "b 200f\n" ~
            "113: mov w9, #104\n" ~ "b 200f\n" ~
            "114: mov w9, #111\n" ~ "b 200f\n" ~
            "115: mov w9, #118\n" ~
            "200: mov %0, w9"
            : "=r" (result)
            : "r" (obj)
            : "x8", "x9";
        }
    } else {
        result = methodResults[obj.typeId < 16 ? obj.typeId : 0];
    }
    
    return result + obj.data;
}

// Chain dispatch 32 types
pragma(inline, false)
int chainDispatch32Asm(Obj* obj) {
    int result;
    
    version (AArch64) {
        asm {
            "ldr w8, [%1]\n" ~
            "cmp w8, #0\n"  ~ "b.eq 300f\n" ~
            "cmp w8, #1\n"  ~ "b.eq 301f\n" ~
            "cmp w8, #2\n"  ~ "b.eq 302f\n" ~
            "cmp w8, #3\n"  ~ "b.eq 303f\n" ~
            "cmp w8, #4\n"  ~ "b.eq 304f\n" ~
            "cmp w8, #5\n"  ~ "b.eq 305f\n" ~
            "cmp w8, #6\n"  ~ "b.eq 306f\n" ~
            "cmp w8, #7\n"  ~ "b.eq 307f\n" ~
            "cmp w8, #8\n"  ~ "b.eq 308f\n" ~
            "cmp w8, #9\n"  ~ "b.eq 309f\n" ~
            "cmp w8, #10\n" ~ "b.eq 310f\n" ~
            "cmp w8, #11\n" ~ "b.eq 311f\n" ~
            "cmp w8, #12\n" ~ "b.eq 312f\n" ~
            "cmp w8, #13\n" ~ "b.eq 313f\n" ~
            "cmp w8, #14\n" ~ "b.eq 314f\n" ~
            "cmp w8, #15\n" ~ "b.eq 315f\n" ~
            "cmp w8, #16\n" ~ "b.eq 316f\n" ~
            "cmp w8, #17\n" ~ "b.eq 317f\n" ~
            "cmp w8, #18\n" ~ "b.eq 318f\n" ~
            "cmp w8, #19\n" ~ "b.eq 319f\n" ~
            "cmp w8, #20\n" ~ "b.eq 320f\n" ~
            "cmp w8, #21\n" ~ "b.eq 321f\n" ~
            "cmp w8, #22\n" ~ "b.eq 322f\n" ~
            "cmp w8, #23\n" ~ "b.eq 323f\n" ~
            "cmp w8, #24\n" ~ "b.eq 324f\n" ~
            "cmp w8, #25\n" ~ "b.eq 325f\n" ~
            "cmp w8, #26\n" ~ "b.eq 326f\n" ~
            "cmp w8, #27\n" ~ "b.eq 327f\n" ~
            "cmp w8, #28\n" ~ "b.eq 328f\n" ~
            "cmp w8, #29\n" ~ "b.eq 329f\n" ~
            "cmp w8, #30\n" ~ "b.eq 330f\n" ~
            "cmp w8, #31\n" ~ "b.eq 331f\n" ~
            "mov w9, #-1\n" ~ "b 400f\n" ~
            "300: mov w9, #13\n"  ~ "b 400f\n" ~
            "301: mov w9, #20\n"  ~ "b 400f\n" ~
            "302: mov w9, #27\n"  ~ "b 400f\n" ~
            "303: mov w9, #34\n"  ~ "b 400f\n" ~
            "304: mov w9, #41\n"  ~ "b 400f\n" ~
            "305: mov w9, #48\n"  ~ "b 400f\n" ~
            "306: mov w9, #55\n"  ~ "b 400f\n" ~
            "307: mov w9, #62\n"  ~ "b 400f\n" ~
            "308: mov w9, #69\n"  ~ "b 400f\n" ~
            "309: mov w9, #76\n"  ~ "b 400f\n" ~
            "310: mov w9, #83\n"  ~ "b 400f\n" ~
            "311: mov w9, #90\n"  ~ "b 400f\n" ~
            "312: mov w9, #97\n"  ~ "b 400f\n" ~
            "313: mov w9, #104\n" ~ "b 400f\n" ~
            "314: mov w9, #111\n" ~ "b 400f\n" ~
            "315: mov w9, #118\n" ~ "b 400f\n" ~
            "316: mov w9, #125\n" ~ "b 400f\n" ~
            "317: mov w9, #132\n" ~ "b 400f\n" ~
            "318: mov w9, #139\n" ~ "b 400f\n" ~
            "319: mov w9, #146\n" ~ "b 400f\n" ~
            "320: mov w9, #153\n" ~ "b 400f\n" ~
            "321: mov w9, #160\n" ~ "b 400f\n" ~
            "322: mov w9, #167\n" ~ "b 400f\n" ~
            "323: mov w9, #174\n" ~ "b 400f\n" ~
            "324: mov w9, #181\n" ~ "b 400f\n" ~
            "325: mov w9, #188\n" ~ "b 400f\n" ~
            "326: mov w9, #195\n" ~ "b 400f\n" ~
            "327: mov w9, #202\n" ~ "b 400f\n" ~
            "328: mov w9, #209\n" ~ "b 400f\n" ~
            "329: mov w9, #216\n" ~ "b 400f\n" ~
            "330: mov w9, #223\n" ~ "b 400f\n" ~
            "331: mov w9, #230\n" ~
            "400: mov %0, w9"
            : "=r" (result)
            : "r" (obj)
            : "x8", "x9";
        }
    } else {
        result = methodResults[obj.typeId < 32 ? obj.typeId : 0];
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
    writeln("Measuring actual instruction costs");
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
    
    writeln("--- Uniform Distribution ---");
    foreach (test; tests) {
        Obj[] objs;
        foreach (i; 0 .. POOL_SIZE) {
            objs ~= Obj(i % test.types, i);
        }
        
        int sum1 = 0;
        auto sw1 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum1 += vtableDispatchAsm(&objs[i % POOL_SIZE]);
        }
        sw1.stop();
        
        int sum2 = 0;
        auto sw2 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum2 += test.chainFn(&objs[i % POOL_SIZE]);
        }
        sw2.stop();
        
        printResult(Result(test.types, "uniform", 
            cast(double)sw1.peek().total!"nsecs" / ITERATIONS,
            cast(double)sw2.peek().total!"nsecs" / ITERATIONS,
            cast(double)sw2.peek().total!"nsecs" / sw1.peek().total!"nsecs"));
    }
    
    writeln();
    writeln("--- Monomorphic (type 0) ---");
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
        
        int sum2 = 0;
        auto sw2 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum2 += test.chainFn(&objs[i % POOL_SIZE]);
        }
        sw2.stop();
        
        printResult(Result(test.types, "mono", 
            cast(double)sw1.peek().total!"nsecs" / ITERATIONS,
            cast(double)sw2.peek().total!"nsecs" / ITERATIONS,
            cast(double)sw2.peek().total!"nsecs" / sw1.peek().total!"nsecs"));
    }
    
    writeln();
    writeln("--- Worst Case (last type) ---");
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
        
        int sum2 = 0;
        auto sw2 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum2 += test.chainFn(&objs[i % POOL_SIZE]);
        }
        sw2.stop();
        
        printResult(Result(test.types, "worst", 
            cast(double)sw1.peek().total!"nsecs" / ITERATIONS,
            cast(double)sw2.peek().total!"nsecs" / ITERATIONS,
            cast(double)sw2.peek().total!"nsecs" / sw1.peek().total!"nsecs"));
    }
    
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
        
        int sum2 = 0;
        auto sw2 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum2 += test.chainFn(&objs[i % POOL_SIZE]);
        }
        sw2.stop();
        
        printResult(Result(test.types, "random", 
            cast(double)sw1.peek().total!"nsecs" / ITERATIONS,
            cast(double)sw2.peek().total!"nsecs" / ITERATIONS,
            cast(double)sw2.peek().total!"nsecs" / sw1.peek().total!"nsecs"));
    }
    
    writeln();
    writeln("Note: ratio < 1 = chain wins, > 1 = vtable wins");
}
