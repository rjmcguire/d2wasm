/**
 * Scaling test for dispatch mechanisms.
 * Find the crossover point where vtable or chain wins by >7x.
 */
module simulate_dispatch_scaling;

import std.stdio;
import std.datetime.stopwatch;
import std.random;
import std.format;

struct Obj {
    uint typeId;
}

// Generate method functions at compile time
static foreach (i; 0 .. 256) {
    mixin(format!`pragma(inline, false) int method%d() { return %d; }`(i, i));
}

// Vtable
alias MethodPtr = int function();
__gshared MethodPtr[256] vtable;
__gshared MethodPtr*[256] objectVtables;

shared static this() {
    static foreach (i; 0 .. 256) {
        mixin(format!`vtable[%d] = &method%d;`(i, i));
    }
    for (int i = 0; i < 256; i++) {
        objectVtables[i] = &vtable[i];
    }
}

pragma(inline, false)
int dispatchVtable(Obj* obj) {
    auto vt = objectVtables[obj.typeId];
    return (*vt)();
}

// Chain dispatch generators using string mixins
string generateChain(int n)() {
    string code = "pragma(inline, false) int dispatchChain" ~ n.stringof ~ "(Obj* obj) {\n";
    code ~= "    uint tid = obj.typeId;\n";
    static foreach (i; 0 .. n) {
        code ~= format!"    if (tid == %d) return method%d();\n"(i, i);
    }
    code ~= "    return -1;\n}\n";
    return code;
}

// Generate chain dispatchers for various sizes
mixin(generateChain!4());
mixin(generateChain!8());
mixin(generateChain!16());
mixin(generateChain!32());
mixin(generateChain!64());
mixin(generateChain!128());
mixin(generateChain!256());

struct Result {
    int types;
    double vtableNs;
    double chainNs;
    double ratio;  // chain/vtable, <1 means chain wins
}

Result runTest(int numTypes, int function(Obj*) chainDispatch, long iterations) {
    enum POOL_SIZE = 10_000;
    auto rng = Random(42);
    
    // Create uniform distribution of types
    Obj[] objs;
    foreach (i; 0 .. POOL_SIZE) {
        objs ~= Obj(i % numTypes);
    }
    
    // Benchmark vtable
    int sum1 = 0;
    auto sw1 = StopWatch(AutoStart.yes);
    for (long i = 0; i < iterations; i++) {
        sum1 += dispatchVtable(&objs[i % POOL_SIZE]);
    }
    sw1.stop();
    double vtableNs = cast(double)sw1.peek().total!"nsecs" / iterations;
    
    // Benchmark chain
    int sum2 = 0;
    auto sw2 = StopWatch(AutoStart.yes);
    for (long i = 0; i < iterations; i++) {
        sum2 += chainDispatch(&objs[i % POOL_SIZE]);
    }
    sw2.stop();
    double chainNs = cast(double)sw2.peek().total!"nsecs" / iterations;
    
    // Verify same results
    assert(sum1 == sum2, "Checksum mismatch!");
    
    return Result(numTypes, vtableNs, chainNs, chainNs / vtableNs);
}

Result runWorstCase(int numTypes, int function(Obj*) chainDispatch, long iterations) {
    enum POOL_SIZE = 10_000;
    
    // All instances are the LAST type (worst case for chain)
    Obj[] objs;
    foreach (i; 0 .. POOL_SIZE) {
        objs ~= Obj(numTypes - 1);
    }
    
    int sum1 = 0;
    auto sw1 = StopWatch(AutoStart.yes);
    for (long i = 0; i < iterations; i++) {
        sum1 += dispatchVtable(&objs[i % POOL_SIZE]);
    }
    sw1.stop();
    double vtableNs = cast(double)sw1.peek().total!"nsecs" / iterations;
    
    int sum2 = 0;
    auto sw2 = StopWatch(AutoStart.yes);
    for (long i = 0; i < iterations; i++) {
        sum2 += chainDispatch(&objs[i % POOL_SIZE]);
    }
    sw2.stop();
    double chainNs = cast(double)sw2.peek().total!"nsecs" / iterations;
    
    return Result(numTypes, vtableNs, chainNs, chainNs / vtableNs);
}

void main() {
    enum ITERATIONS = 50_000_000;
    
    writeln("=== Dispatch Scaling Test ===");
    writeln("Looking for >7x difference...");
    writeln();
    
    // Uniform distribution tests
    writeln("--- Uniform Distribution (all types equally likely) ---");
    writefln("%6s %10s %10s %10s %s", "Types", "vtable", "chain", "ratio", "winner");
    writeln("--------------------------------------------------------------");
    
    Result[] uniformResults;
    uniformResults ~= runTest(4, &dispatchChain4, ITERATIONS);
    uniformResults ~= runTest(8, &dispatchChain8, ITERATIONS);
    uniformResults ~= runTest(16, &dispatchChain16, ITERATIONS);
    uniformResults ~= runTest(32, &dispatchChain32, ITERATIONS);
    uniformResults ~= runTest(64, &dispatchChain64, ITERATIONS);
    uniformResults ~= runTest(128, &dispatchChain128, ITERATIONS);
    uniformResults ~= runTest(256, &dispatchChain256, ITERATIONS);
    
    foreach (r; uniformResults) {
        string winner = r.ratio < 1 ? "CHAIN" : "VTABLE";
        string marker = (r.ratio < 1.0/7.0 || r.ratio > 7.0) ? " <<<" : "";
        writefln("%6d %8.2f ns %8.2f ns %9.2fx %s%s", 
            r.types, r.vtableNs, r.chainNs, r.ratio, winner, marker);
    }
    
    writeln();
    writeln("--- Worst Case (always last type in chain) ---");
    writefln("%6s %10s %10s %10s %s", "Types", "vtable", "chain", "ratio", "winner");
    writeln("--------------------------------------------------------------");
    
    Result[] worstResults;
    worstResults ~= runWorstCase(4, &dispatchChain4, ITERATIONS);
    worstResults ~= runWorstCase(8, &dispatchChain8, ITERATIONS);
    worstResults ~= runWorstCase(16, &dispatchChain16, ITERATIONS);
    worstResults ~= runWorstCase(32, &dispatchChain32, ITERATIONS);
    worstResults ~= runWorstCase(64, &dispatchChain64, ITERATIONS);
    worstResults ~= runWorstCase(128, &dispatchChain128, ITERATIONS);
    worstResults ~= runWorstCase(256, &dispatchChain256, ITERATIONS);
    
    foreach (r; worstResults) {
        string winner = r.ratio < 1 ? "CHAIN" : "VTABLE";
        string marker = (r.ratio < 1.0/7.0 || r.ratio > 7.0) ? " <<<" : "";
        writefln("%6d %8.2f ns %8.2f ns %9.2fx %s%s", 
            r.types, r.vtableNs, r.chainNs, r.ratio, winner, marker);
    }
    
    writeln();
    writeln("--- Monomorphic (always type 0) ---");
    writefln("%6s %10s %10s %10s %s", "Types", "vtable", "chain", "ratio", "winner");
    writeln("--------------------------------------------------------------");
    
    // For monomorphic, chain length doesn't matter much
    Result[] monoResults;
    
    // Test with chain256 but all type 0
    {
        enum POOL_SIZE = 10_000;
        Obj[] objs;
        foreach (i; 0 .. POOL_SIZE) {
            objs ~= Obj(0);  // Always type 0
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
            sum2 += dispatchChain256(&objs[i % POOL_SIZE]);
        }
        sw2.stop();
        
        double vtableNs = cast(double)sw1.peek().total!"nsecs" / ITERATIONS;
        double chainNs = cast(double)sw2.peek().total!"nsecs" / ITERATIONS;
        
        writefln("%6d %8.2f ns %8.2f ns %9.2fx %s", 
            256, vtableNs, chainNs, chainNs/vtableNs, 
            chainNs/vtableNs < 1 ? "CHAIN" : "VTABLE");
    }
    
    writeln();
    writeln("Done. Ratio < 0.14 means chain wins by >7x, > 7.0 means vtable wins by >7x");
}
