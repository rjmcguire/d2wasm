/**
 * Scaling test for dispatch mechanisms - with optimization prevention.
 * 
 * Uses volatile reads and non-trivial return values to prevent
 * the compiler from optimizing away the dispatch.
 */
module simulate_dispatch_real;

import std.stdio;
import std.datetime.stopwatch;
import std.random;
import core.volatile;

struct Obj {
    uint typeId;
    int data;  // Extra data to make methods non-trivial
}

// Shared state to prevent optimization
__gshared int[256] methodState;

shared static this() {
    foreach (i; 0 .. 256) {
        methodState[i] = i * 7 + 13;  // Non-trivial values
    }
}

// Generate methods that read from volatile state
static foreach (i; 0 .. 256) {
    mixin((){
        import std.format;
        return format!`
pragma(inline, false)
int method%d(Obj* obj) { 
    return volatileLoad(&methodState[%d]) + obj.data;
}`(i, i);
    }());
}

// Vtable
alias MethodPtr = int function(Obj*);
__gshared MethodPtr[256] vtable;

shared static this() {
    static foreach (i; 0 .. 256) {
        mixin((){
            import std.format;
            return format!`vtable[%d] = &method%d;`(i, i);
        }());
    }
}

pragma(inline, false)
int dispatchVtable(Obj* obj) {
    return vtable[obj.typeId](obj);
}

// Chain dispatch - manually written to prevent optimization
pragma(inline, false)
int dispatchChain4(Obj* obj) {
    uint tid = volatileLoad(&obj.typeId);
    if (tid == 0) return method0(obj);
    if (tid == 1) return method1(obj);
    if (tid == 2) return method2(obj);
    if (tid == 3) return method3(obj);
    return -1;
}

pragma(inline, false)
int dispatchChain8(Obj* obj) {
    uint tid = volatileLoad(&obj.typeId);
    if (tid == 0) return method0(obj);
    if (tid == 1) return method1(obj);
    if (tid == 2) return method2(obj);
    if (tid == 3) return method3(obj);
    if (tid == 4) return method4(obj);
    if (tid == 5) return method5(obj);
    if (tid == 6) return method6(obj);
    if (tid == 7) return method7(obj);
    return -1;
}

pragma(inline, false)
int dispatchChain16(Obj* obj) {
    uint tid = volatileLoad(&obj.typeId);
    if (tid == 0) return method0(obj);
    if (tid == 1) return method1(obj);
    if (tid == 2) return method2(obj);
    if (tid == 3) return method3(obj);
    if (tid == 4) return method4(obj);
    if (tid == 5) return method5(obj);
    if (tid == 6) return method6(obj);
    if (tid == 7) return method7(obj);
    if (tid == 8) return method8(obj);
    if (tid == 9) return method9(obj);
    if (tid == 10) return method10(obj);
    if (tid == 11) return method11(obj);
    if (tid == 12) return method12(obj);
    if (tid == 13) return method13(obj);
    if (tid == 14) return method14(obj);
    if (tid == 15) return method15(obj);
    return -1;
}

pragma(inline, false)
int dispatchChain32(Obj* obj) {
    uint tid = volatileLoad(&obj.typeId);
    static foreach (i; 0 .. 32) {
        if (tid == i) mixin("return method" ~ i.stringof ~ "(obj);");
    }
    return -1;
}

pragma(inline, false)
int dispatchChain64(Obj* obj) {
    uint tid = volatileLoad(&obj.typeId);
    static foreach (i; 0 .. 64) {
        if (tid == i) mixin("return method" ~ i.stringof ~ "(obj);");
    }
    return -1;
}

pragma(inline, false)
int dispatchChain128(Obj* obj) {
    uint tid = volatileLoad(&obj.typeId);
    static foreach (i; 0 .. 128) {
        if (tid == i) mixin("return method" ~ i.stringof ~ "(obj);");
    }
    return -1;
}

pragma(inline, false)
int dispatchChain256(Obj* obj) {
    uint tid = volatileLoad(&obj.typeId);
    static foreach (i; 0 .. 256) {
        if (tid == i) mixin("return method" ~ i.stringof ~ "(obj);");
    }
    return -1;
}

struct Result {
    int types;
    double vtableNs;
    double chainNs;
    double ratio;
}

Result runTest(string label, int numTypes, int function(Obj*) chainDispatch, long iterations) {
    enum POOL_SIZE = 10_000;
    
    Obj[] objs;
    foreach (i; 0 .. POOL_SIZE) {
        objs ~= Obj(i % numTypes, i);
    }
    
    // Warmup
    int warmup = 0;
    foreach (i; 0 .. 1000) {
        warmup += dispatchVtable(&objs[i % POOL_SIZE]);
        warmup += chainDispatch(&objs[i % POOL_SIZE]);
    }
    
    // Benchmark vtable
    int sum1 = warmup;
    auto sw1 = StopWatch(AutoStart.yes);
    for (long i = 0; i < iterations; i++) {
        sum1 += dispatchVtable(&objs[i % POOL_SIZE]);
    }
    sw1.stop();
    double vtableNs = cast(double)sw1.peek().total!"nsecs" / iterations;
    
    // Benchmark chain
    int sum2 = warmup;
    auto sw2 = StopWatch(AutoStart.yes);
    for (long i = 0; i < iterations; i++) {
        sum2 += chainDispatch(&objs[i % POOL_SIZE]);
    }
    sw2.stop();
    double chainNs = cast(double)sw2.peek().total!"nsecs" / iterations;
    
    return Result(numTypes, vtableNs, chainNs, chainNs / vtableNs);
}

void printResult(Result r) {
    string winner = r.ratio < 1 ? "CHAIN" : "VTABLE";
    double factor = r.ratio < 1 ? 1.0/r.ratio : r.ratio;
    string marker = factor > 7.0 ? " <<< >7x!" : "";
    writefln("%6d %8.2f ns %8.2f ns %9.2fx %s%s", 
        r.types, r.vtableNs, r.chainNs, r.ratio, winner, marker);
}

void main() {
    enum ITERATIONS = 20_000_000;
    
    writeln("=== Dispatch Scaling Test (with optimization prevention) ===");
    writeln();
    
    writeln("--- Uniform Distribution ---");
    writefln("%6s %10s %10s %10s %s", "Types", "vtable", "chain", "ratio", "winner");
    writeln("--------------------------------------------------------------");
    
    printResult(runTest("uniform", 4, &dispatchChain4, ITERATIONS));
    printResult(runTest("uniform", 8, &dispatchChain8, ITERATIONS));
    printResult(runTest("uniform", 16, &dispatchChain16, ITERATIONS));
    printResult(runTest("uniform", 32, &dispatchChain32, ITERATIONS));
    printResult(runTest("uniform", 64, &dispatchChain64, ITERATIONS));
    printResult(runTest("uniform", 128, &dispatchChain128, ITERATIONS));
    printResult(runTest("uniform", 256, &dispatchChain256, ITERATIONS));
    
    writeln();
    writeln("--- Worst Case (always last type) ---");
    writefln("%6s %10s %10s %10s %s", "Types", "vtable", "chain", "ratio", "winner");
    writeln("--------------------------------------------------------------");
    
    // Worst case: all instances are last type
    foreach (testCase; [
        tuple(4, &dispatchChain4),
        tuple(8, &dispatchChain8),
        tuple(16, &dispatchChain16),
        tuple(32, &dispatchChain32),
        tuple(64, &dispatchChain64),
        tuple(128, &dispatchChain128),
        tuple(256, &dispatchChain256),
    ]) {
        int numTypes = testCase[0];
        auto chainFn = testCase[1];
        
        enum POOL_SIZE = 10_000;
        Obj[] objs;
        foreach (i; 0 .. POOL_SIZE) {
            objs ~= Obj(numTypes - 1, i);  // Always last type
        }
        
        int sum1 = 0;
        auto sw1 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum1 += dispatchVtable(&objs[i % POOL_SIZE]);
        }
        sw1.stop();
        
        int sum2 = 0;
        auto sw2 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum2 += chainFn(&objs[i % POOL_SIZE]);
        }
        sw2.stop();
        
        double vtableNs = cast(double)sw1.peek().total!"nsecs" / ITERATIONS;
        double chainNs = cast(double)sw2.peek().total!"nsecs" / ITERATIONS;
        printResult(Result(numTypes, vtableNs, chainNs, chainNs / vtableNs));
    }
    
    writeln();
    writeln("Ratio < 0.14 = chain wins by >7x");
    writeln("Ratio > 7.0  = vtable wins by >7x");
}

auto tuple(T...)(T args) {
    struct Tuple { T expand; }
    return Tuple(args);
}
