/**
 * Dispatch scaling test v3 - using actual virtual method calls.
 * 
 * We'll use D's actual class/interface mechanism for vtable,
 * and compare against a manually-written switch dispatch.
 */
module simulate_v3;

import std.stdio;
import std.datetime.stopwatch;
import std.random;

// Interface for our test
interface IMethod {
    int getValue(int x);
}

// Generate concrete classes
static foreach (i; 0 .. 256) {
    mixin(() {
        import std.format;
        return format!`
class C%d : IMethod {
    override int getValue(int x) { 
        return x * %d + %d; 
    }
}`(i, i + 1, i * 7);
    }());
}

// Factory function
IMethod createInstance(int typeId) {
    final switch (typeId & 0xFF) {
        static foreach (i; 0 .. 256) {
            mixin(() {
                import std.format;
                return format!`case %d: return new C%d();`(i, i);
            }());
        }
    }
}

// Switch-based dispatch (simulates chain)
pragma(inline, false)
int switchDispatch(int typeId, int x) {
    final switch (typeId & 0xFF) {
        static foreach (i; 0 .. 256) {
            mixin(() {
                import std.format;
                return format!`case %d: return x * %d + %d;`(i, i + 1, i * 7);
            }());
        }
    }
}

// Bounded switch dispatches
pragma(inline, false)
int switchDispatch4(int typeId, int x) {
    switch (typeId) {
        case 0: return x * 1 + 0;
        case 1: return x * 2 + 7;
        case 2: return x * 3 + 14;
        case 3: return x * 4 + 21;
        default: return -1;
    }
}

pragma(inline, false)
int switchDispatch16(int typeId, int x) {
    switch (typeId) {
        static foreach (i; 0 .. 16) {
            mixin(() {
                import std.format;
                return format!`case %d: return x * %d + %d;`(i, i + 1, i * 7);
            }());
        }
        default: return -1;
    }
}

pragma(inline, false)
int switchDispatch64(int typeId, int x) {
    switch (typeId) {
        static foreach (i; 0 .. 64) {
            mixin(() {
                import std.format;
                return format!`case %d: return x * %d + %d;`(i, i + 1, i * 7);
            }());
        }
        default: return -1;
    }
}

struct Result {
    int types;
    double vtableNs;
    double switchNs;
    double ratio;
}

void main() {
    enum ITERATIONS = 20_000_000;
    enum POOL_SIZE = 10_000;
    
    writeln("=== Dispatch Scaling Test v3 (D classes vs switch) ===");
    writeln();
    
    auto rng = Random(42);
    
    // Test different type counts
    foreach (numTypes; [4, 8, 16, 32, 64, 128, 256]) {
        // Create instances
        IMethod[] instances;
        int[] typeIds;
        int[] args;
        
        foreach (i; 0 .. POOL_SIZE) {
            int tid = i % numTypes;
            instances ~= createInstance(tid);
            typeIds ~= tid;
            args ~= i;
        }
        
        // Warmup
        int warmup = 0;
        foreach (i; 0 .. 1000) {
            warmup += instances[i % POOL_SIZE].getValue(args[i % POOL_SIZE]);
            warmup += switchDispatch(typeIds[i % POOL_SIZE], args[i % POOL_SIZE]);
        }
        
        // Benchmark vtable (interface call)
        int sum1 = warmup;
        auto sw1 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum1 += instances[i % POOL_SIZE].getValue(args[i % POOL_SIZE]);
        }
        sw1.stop();
        double vtableNs = cast(double)sw1.peek().total!"nsecs" / ITERATIONS;
        
        // Benchmark switch
        int sum2 = warmup;
        auto sw2 = StopWatch(AutoStart.yes);
        for (long i = 0; i < ITERATIONS; i++) {
            sum2 += switchDispatch(typeIds[i % POOL_SIZE], args[i % POOL_SIZE]);
        }
        sw2.stop();
        double switchNs = cast(double)sw2.peek().total!"nsecs" / ITERATIONS;
        
        // Verify
        if (sum1 != sum2) {
            writefln("Warning: checksum mismatch for %d types", numTypes);
        }
        
        double ratio = switchNs / vtableNs;
        string winner = ratio < 1 ? "SWITCH" : "VTABLE";
        double factor = ratio < 1 ? 1.0/ratio : ratio;
        string marker = factor > 7.0 ? " <<< >7x!" : "";
        
        writefln("Types: %3d | vtable: %6.2f ns | switch: %6.2f ns | ratio: %5.2fx | %s%s",
            numTypes, vtableNs, switchNs, ratio, winner, marker);
    }
    
    writeln();
    writeln("--- Worst case: always last type ---");
    
    foreach (numTypes; [4, 16, 64, 256]) {
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
            sum2 += switchDispatch(typeIds[i % POOL_SIZE], args[i % POOL_SIZE]);
        }
        sw2.stop();
        double switchNs = cast(double)sw2.peek().total!"nsecs" / ITERATIONS;
        
        double ratio = switchNs / vtableNs;
        string winner = ratio < 1 ? "SWITCH" : "VTABLE";
        double factor = ratio < 1 ? 1.0/ratio : ratio;
        string marker = factor > 7.0 ? " <<< >7x!" : "";
        
        writefln("Types: %3d (last) | vtable: %6.2f ns | switch: %6.2f ns | ratio: %5.2fx | %s%s",
            numTypes, vtableNs, switchNs, ratio, winner, marker);
    }
    
    writeln();
    writeln("--- Monomorphic: always type 0 ---");
    
    {
        IMethod[] instances;
        int[] typeIds;
        int[] args;
        
        foreach (i; 0 .. POOL_SIZE) {
            instances ~= createInstance(0);
            typeIds ~= 0;
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
            sum2 += switchDispatch(typeIds[i % POOL_SIZE], args[i % POOL_SIZE]);
        }
        sw2.stop();
        double switchNs = cast(double)sw2.peek().total!"nsecs" / ITERATIONS;
        
        double ratio = switchNs / vtableNs;
        string winner = ratio < 1 ? "SWITCH" : "VTABLE";
        
        writefln("Mono type 0 | vtable: %6.2f ns | switch: %6.2f ns | ratio: %5.2fx | %s",
            vtableNs, switchNs, ratio, winner);
    }
    
    writeln();
    writeln("Note: switch with 256 cases likely compiles to jump table (similar to vtable)");
}
