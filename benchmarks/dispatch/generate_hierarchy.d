/**
 * Generates a class hierarchy for benchmarking dispatch mechanisms.
 * 
 * Structure: Tree with configurable branching factor and depth.
 * 
 * Example with branching=10, depth=3:
 *   Base (1)
 *   ├── D1_0 ... D1_9 (10)
 *   │   ├── D2_00 ... D2_09 (100)
 *   │   │   ├── D3_000 ... D3_009 (1000)
 *   │   │   └── ...
 *   │   └── ...
 *   └── ...
 */
module generate_hierarchy;

import std.stdio;
import std.format;
import std.array;
import std.conv;

struct Config {
    int branching = 10;   // Children per node
    int maxDepth = 3;     // How deep the tree goes
    string outputFile = "hierarchy.d";
}

void main(string[] args) {
    Config config;
    
    // Simple arg parsing
    for (int i = 1; i < args.length; i++) {
        if (args[i] == "--branching" && i + 1 < args.length) {
            config.branching = args[++i].to!int;
        } else if (args[i] == "--depth" && i + 1 < args.length) {
            config.maxDepth = args[++i].to!int;
        } else if (args[i] == "--output" && i + 1 < args.length) {
            config.outputFile = args[++i];
        }
    }
    
    auto f = File(config.outputFile, "w");
    
    // Module header
    f.writeln("// Auto-generated class hierarchy for dispatch benchmarking");
    f.writeln("// Branching factor: ", config.branching);
    f.writeln("// Max depth: ", config.maxDepth);
    f.writeln();
    
    // Base class
    f.writeln("class Base {");
    f.writeln("    int getValue() { return -1; }");
    f.writeln("}");
    f.writeln();
    
    // Track class info for later
    string[][] classesByDepth;
    classesByDepth ~= ["Base"];
    
    // Generate each depth level
    for (int depth = 1; depth <= config.maxDepth; depth++) {
        string[] thisLevel;
        string[] parentLevel = classesByDepth[depth - 1];
        
        int classId = 0;
        foreach (parent; parentLevel) {
            for (int child = 0; child < config.branching; child++) {
                string className = format("D%d_%s", depth, toBase(classId, config.branching, depth));
                thisLevel ~= className;
                
                f.writefln("class %s : %s {", className, parent);
                f.writefln("    override int getValue() { return %d; }", depth * 10000 + classId);
                f.writeln("}");
                
                classId++;
            }
        }
        
        classesByDepth ~= thisLevel;
        f.writeln();
    }
    
    // Generate factory function
    f.writeln("// Factory to create instance by type ID");
    f.writeln("Base createByTypeId(int typeId) {");
    f.writeln("    switch (typeId) {");
    
    int typeId = 0;
    for (int depth = 1; depth < classesByDepth.length; depth++) {
        foreach (className; classesByDepth[depth]) {
            f.writefln("        case %d: return new %s();", typeId, className);
            typeId++;
        }
    }
    
    f.writeln("        default: return new Base();");
    f.writeln("    }");
    f.writeln("}");
    f.writeln();
    
    // Generate type count constant
    int totalTypes = typeId;
    f.writefln("enum TOTAL_TYPES = %d;", totalTypes);
    f.writeln();
    
    // Summary
    f.writeln("/*");
    f.writeln(" * Hierarchy summary:");
    for (int depth = 0; depth < classesByDepth.length; depth++) {
        f.writefln(" *   Depth %d: %d classes", depth, classesByDepth[depth].length);
    }
    f.writefln(" *   Total: %d classes (excluding Base)", totalTypes);
    f.writeln(" */");
    
    stderr.writefln("Generated %s with %d classes", config.outputFile, totalTypes);
}

// Convert number to zero-padded base-N representation for naming
string toBase(int num, int base, int digits) {
    char[] result;
    result.length = digits;
    
    for (int i = digits - 1; i >= 0; i--) {
        result[i] = cast(char)('0' + (num % base));
        num /= base;
    }
    
    return result.idup;
}
