/**
 * TRUE chain dispatch - using nested if-else that can't become a jump table.
 * We randomize the comparison order to prevent pattern optimization.
 */
module chain_true;

import std.stdio;
import std.datetime.stopwatch;
import std.random;

interface IMethod {
    int getValue(int x);
}

// Generate classes
static foreach (i; 0 .. 512) {
    mixin(() {
        import std.format;
        return format!`
class C%d : IMethod {
    override int getValue(int x) { return x * %d + %d; }
}`(i, i + 1, i * 7);
    }());
}

IMethod createInstance(int typeId) {
    switch (typeId) {
        static foreach (i; 0 .. 512) {
            mixin(() {
                import std.format;
                return format!`case %d: return new C%d();`(i, i);
            }());
        }
        default: return new C0();
    }
}

// True chain: nested if-else (harder to optimize to jump table)
// Using function pointers to prevent inlining
alias ChainFn = int function(int typeId, int x);
__gshared ChainFn[512] chainTable;

shared static this() {
    static foreach (i; 0 .. 512) {
        chainTable[i] = (int typeId, int x) {
            mixin(() {
                import std.format;
                return format!`if (typeId == %d) return x * %d + %d;`(i, i + 1, i * 7);
            }());
            // Chain to next
            static if (i < 511) {
                return chainTable[i + 1](typeId, x);
            } else {
                return -1;
            }
        };
    }
}

pragma(inline, false)
int chainDispatch(int typeId, int x) {
    return chainTable[0](typeId, x);
}

// For comparison: linear search (true O(n) chain)
pragma(inline, false)
int linearDispatch(int typeId, int x, int maxTypes) {
    static foreach (i; 0 .. 512) {
        if (i < maxTypes && typeId == i) {
            mixin(() {
                import std.format;
                return format!`return x * %d + %d;`(i + 1, i * 7);
            }());
        }
    }
    return -1;
}

void main() {
    enum ITERATIONS = 10_000_000;
    enum POOL_SIZE = 10_000;
    
    writeln("=== True Chain Dispatch Test ===");
    writeln("Testing: vtable vs linear chain vs chained functions");
    writeln();
    
    foreach (numTypes; [4, 8, 16, 32, 64, 128, 256, 512]) {
        IMethod[] instances;
        int[] typeIds;
        int[] args;
        
        foreach (i; 0 .. POOL_SIZE) {
            int tid = i % numTypes;
            instances ~= createInstance(tid);
            typeIds ~= tid;
            args ~= i;
        }
        
        // Vtable
        int sum1 = 0;
        auto sw1 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum1 += instances[i % POOL_SIZE].getValue(args[i % POOL_SIZE]);
        }
        sw1.stop();
        double vtableNs = cast(double)sw1.peek().total!"nsecs" / ITERATIONS;
        
        // Chained functions
        int sum2 = 0;
        auto sw2 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum2 += chainDispatch(typeIds[i % POOL_SIZE], args[i % POOL_SIZE]);
        }
        sw2.stop();
        double chainNs = cast(double)sw2.peek().total!"nsecs" / ITERATIONS;
        
        double ratio = chainNs / vtableNs;
        string winner = ratio < 1 ? "CHAIN" : "VTABLE";
        double factor = ratio < 1 ? 1.0/ratio : ratio;
        string marker = factor > 7.0 ? " <<< >7x!" : "";
        
        writefln("Types: %3d | vtable: %7.2f ns | chain: %7.2f ns | ratio: %6.2fx | %s%s",
            numTypes, vtableNs, chainNs, ratio, winner, marker);
    }
    
    writeln();
    writeln("--- Worst case: always LAST type (max chain walk) ---");
    
    foreach (numTypes; [4, 16, 64, 256, 512]) {
        IMethod[] instances;
        int[] typeIds;
        int[] args;
        
        int lastType = numTypes - 1;
        foreach (i; 0 .. POOL_SIZE) {
            instances ~= createInstance(lastType);
            typeIds ~= lastType;
            args ~= i;
        }
        
        int sum1 = 0;
        auto sw1 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum1 += instances[i % POOL_SIZE].getValue(args[i % POOL_SIZE]);
        }
        sw1.stop();
        double vtableNs = cast(double)sw1.peek().total!"nsecs" / ITERATIONS;
        
        int sum2 = 0;
        auto sw2 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum2 += chainDispatch(typeIds[i % POOL_SIZE], args[i % POOL_SIZE]);
        }
        sw2.stop();
        double chainNs = cast(double)sw2.peek().total!"nsecs" / ITERATIONS;
        
        double ratio = chainNs / vtableNs;
        string winner = ratio < 1 ? "CHAIN" : "VTABLE";
        double factor = ratio < 1 ? 1.0/ratio : ratio;
        string marker = factor > 7.0 ? " <<< >7x!" : "";
        
        writefln("Types: %3d LAST | vtable: %7.2f ns | chain: %7.2f ns | ratio: %6.2fx | %s%s",
            numTypes, vtableNs, chainNs, ratio, winner, marker);
    }
    
    writeln();
    writeln("--- Random distribution (unpredictable) ---");
    
    auto rng = Random(42);
    foreach (numTypes; [4, 16, 64, 256]) {
        IMethod[] instances;
        int[] typeIds;
        int[] args;
        
        foreach (i; 0 .. POOL_SIZE) {
            int tid = uniform(0, numTypes, rng);
            instances ~= createInstance(tid);
            typeIds ~= tid;
            args ~= i;
        }
        
        int sum1 = 0;
        auto sw1 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum1 += instances[i % POOL_SIZE].getValue(args[i % POOL_SIZE]);
        }
        sw1.stop();
        double vtableNs = cast(double)sw1.peek().total!"nsecs" / ITERATIONS;
        
        int sum2 = 0;
        auto sw2 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum2 += chainDispatch(typeIds[i % POOL_SIZE], args[i % POOL_SIZE]);
        }
        sw2.stop();
        double chainNs = cast(double)sw2.peek().total!"nsecs" / ITERATIONS;
        
        double ratio = chainNs / vtableNs;
        string winner = ratio < 1 ? "CHAIN" : "VTABLE";
        double factor = ratio < 1 ? 1.0/ratio : ratio;
        string marker = factor > 7.0 ? " <<< >7x!" : "";
        
        writefln("Types: %3d RAND | vtable: %7.2f ns | chain: %7.2f ns | ratio: %6.2fx | %s%s",
            numTypes, vtableNs, chainNs, ratio, winner, marker);
    }
}
