/**
 * Logging utilities with verbosity levels
 * 
 * Usage:
 *   log(1, "Compiling...");        // -v
 *   log(2, "Processing func: ", name);  // -vv  
 *   log(3, "AST node: ", node);    // -vvv
 */
module diagnostic.log;

import std.stdio : stderr, writeln;
import std.conv : to;

/// Global verbosity level (0 = quiet, 1 = -v, 2 = -vv, 3 = -vvv)
private __gshared int g_verbosity = 0;

/// Set the global verbosity level
void setVerbosity(int level) {
    g_verbosity = level;
}

/// Get current verbosity level
int getVerbosity() {
    return g_verbosity;
}

/// Log a message if verbosity is at or above the given level
void log(T...)(int level, T args) {
    if (g_verbosity >= level) {
        stderr.writeln(args);
    }
}

/// Convenience aliases for common levels
void log1(T...)(T args) { log(1, args); }  // -v
void log2(T...)(T args) { log(2, args); }  // -vv
void log3(T...)(T args) { log(3, args); }  // -vvv

/// For debug output that should always print (errors, warnings)
void logAlways(T...)(T args) {
    stderr.writeln(args);
}
