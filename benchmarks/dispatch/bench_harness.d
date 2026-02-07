/**
 * Benchmark harness for comparing dispatch mechanisms.
 * 
 * Tests:
 * 1. Monomorphic - all same type (best case for inline cache)
 * 2. Uniform leaves - random leaf types only
 * 3. Mixed depth - types from all levels
 * 4. Worst case - always the deepest type that requires full chain walk
 */
module bench_harness;

import std.stdio;
import std.datetime.stopwatch;
import std.random;
import std.format;

// Expects to be combined with generated hierarchy that provides:
//   - class Base
//   - createByTypeId(int) function  
//   - TOTAL_TYPES enum

struct BenchResult {
    string name;
    long iterations;
    Duration elapsed;
    double opsPerSec;
    int checksum;  // To prevent optimizer from eliminating the loop
}

BenchResult runBench(string name, Base[] instances, long iterations) {
    int sum = 0;
    
    auto sw = StopWatch(AutoStart.yes);
    
    for (long i = 0; i < iterations; i++) {
        sum += instances[i % instances.length].getValue();
    }
    
    sw.stop();
    
    return BenchResult(
        name,
        iterations,
        sw.peek(),
        cast(double)iterations / (sw.peek().total!"nsecs" / 1_000_000_000.0),
        sum
    );
}

void printResult(BenchResult r) {
    writefln("%-20s %12d iterations, %8.2f ms, %12.2f ops/sec (checksum: %d)",
        r.name,
        r.iterations,
        r.elapsed.total!"usecs" / 1000.0,
        r.opsPerSec,
        r.checksum);
}

void main(string[] args) {
    // Configuration
    long iterations = 10_000_000;
    int instanceCount = 10_000;
    uint seed = 12345;
    
    // Parse args
    for (int i = 1; i < args.length; i++) {
        if (args[i] == "--iterations" && i + 1 < args.length) {
            import std.conv : to;
            iterations = args[++i].to!long;
        } else if (args[i] == "--instances" && i + 1 < args.length) {
            import std.conv : to;
            instanceCount = args[++i].to!int;
        } else if (args[i] == "--seed" && i + 1 < args.length) {
            import std.conv : to;
            seed = args[++i].to!uint;
        }
    }
    
    auto rng = Random(seed);
    
    writeln("=== Dispatch Benchmark ===");
    writefln("Iterations: %d, Instance pool: %d, Seed: %d", iterations, instanceCount, seed);
    writefln("Total types in hierarchy: %d", TOTAL_TYPES);
    writeln();
    
    // Test 1: Monomorphic (all same type)
    {
        Base[] instances;
        foreach (_; 0 .. instanceCount) {
            instances ~= createByTypeId(0);  // All same type
        }
        auto result = runBench("Monomorphic", instances, iterations);
        printResult(result);
    }
    
    // Test 2: Dimorphic (two types alternating)
    {
        Base[] instances;
        foreach (i; 0 .. instanceCount) {
            instances ~= createByTypeId(i % 2);
        }
        auto result = runBench("Dimorphic", instances, iterations);
        printResult(result);
    }
    
    // Test 3: Few types (8 types)
    {
        Base[] instances;
        foreach (i; 0 .. instanceCount) {
            instances ~= createByTypeId(i % 8);
        }
        auto result = runBench("8 types", instances, iterations);
        printResult(result);
    }
    
    // Test 4: Uniform random across all types
    {
        Base[] instances;
        foreach (_; 0 .. instanceCount) {
            instances ~= createByTypeId(uniform(0, TOTAL_TYPES, rng));
        }
        auto result = runBench("Uniform random", instances, iterations);
        printResult(result);
    }
    
    // Test 5: Skewed (90% type 0, 10% random)
    {
        Base[] instances;
        foreach (_; 0 .. instanceCount) {
            if (uniform(0, 100, rng) < 90) {
                instances ~= createByTypeId(0);
            } else {
                instances ~= createByTypeId(uniform(0, TOTAL_TYPES, rng));
            }
        }
        auto result = runBench("Skewed 90/10", instances, iterations);
        printResult(result);
    }
    
    // Test 6: Sequential (cycles through types in order)
    {
        Base[] instances;
        foreach (i; 0 .. instanceCount) {
            instances ~= createByTypeId(i % TOTAL_TYPES);
        }
        auto result = runBench("Sequential", instances, iterations);
        printResult(result);
    }
    
    writeln();
    writeln("Done.");
}
