/**
 * Error Formatting and Diagnostics
 * 
 * Provides pretty-printed error messages with source context,
 * similar to rustc/clang style diagnostics.
 */
module diagnostic.error_format;

import std.stdio;
import std.string;
import std.file;
import std.array;
import std.algorithm;
import std.conv;
import std.range;
import ast.nodes : SourceLocation;

/// ANSI color codes (disabled if not a TTY)
struct Colors {
    static bool enabled = true;
    
    static string red()     { return enabled ? "\033[1;31m" : ""; }
    static string yellow()  { return enabled ? "\033[1;33m" : ""; }
    static string blue()    { return enabled ? "\033[1;34m" : ""; }
    static string cyan()    { return enabled ? "\033[1;36m" : ""; }
    static string white()   { return enabled ? "\033[1;37m" : ""; }
    static string reset()   { return enabled ? "\033[0m" : ""; }
    static string dim()     { return enabled ? "\033[2m" : ""; }
}

/**
 * Format a compiler error with source context
 */
string formatError(string errorType, string message, SourceLocation loc, string hint = "") {
    auto result = appender!string;
    
    // Header: error[TYPE]: message
    result ~= Colors.red();
    result ~= "error";
    result ~= Colors.reset();
    result ~= ": ";
    result ~= Colors.white();
    result ~= message;
    result ~= Colors.reset();
    result ~= "\n";
    
    // Location line: --> file:line:col
    result ~= Colors.blue();
    result ~= "  --> ";
    result ~= Colors.reset();
    result ~= loc.filename;
    result ~= ":";
    result ~= to!string(loc.line);
    result ~= ":";
    result ~= to!string(loc.column);
    result ~= "\n";
    
    // Try to read source and show context
    try {
        if (loc.filename.length > 0 && exists(loc.filename)) {
            string source = readText(loc.filename);
            auto lines = source.splitLines();
            
            if (loc.line > 0 && loc.line <= lines.length) {
                string lineNum = to!string(loc.line);
                string padding = repeat(" ", lineNum.length).join();
                string sourceLine = lines[loc.line - 1];
                
                // Empty line with bar
                result ~= Colors.blue();
                result ~= padding;
                result ~= " |\n";
                
                // Source line
                result ~= lineNum;
                result ~= " | ";
                result ~= Colors.reset();
                result ~= sourceLine;
                result ~= "\n";
                
                // Caret line
                result ~= Colors.blue();
                result ~= padding;
                result ~= " | ";
                result ~= Colors.red();
                
                // Calculate caret position (handle tabs)
                uint caretPos = loc.column > 0 ? loc.column - 1 : 0;
                string beforeCaret = "";
                foreach (i, ch; sourceLine) {
                    if (i >= caretPos) break;
                    beforeCaret ~= (ch == '\t') ? '\t' : ' ';
                }
                result ~= beforeCaret;
                result ~= "^";
                
                // If we have end offset, show extent
                if (loc.endOffset > loc.startOffset) {
                    uint extent = loc.endOffset - loc.startOffset;
                    if (extent > 1 && extent < 50) {
                        result ~= repeat("~", extent - 1).join();
                    }
                }
                
                result ~= Colors.reset();
                result ~= "\n";
            }
        }
    } catch (Exception e) {
        // Couldn't read source, just skip context
    }
    
    // Hint if provided
    if (hint.length > 0) {
        result ~= Colors.cyan();
        result ~= "  = help: ";
        result ~= Colors.reset();
        result ~= hint;
        result ~= "\n";
    }
    
    return result.data;
}

/**
 * Format a note (secondary diagnostic) with source context
 */
string formatNote(string message, SourceLocation loc) {
    auto result = appender!string;

    result ~= Colors.cyan();
    result ~= "note";
    result ~= Colors.reset();
    result ~= ": ";
    result ~= message;
    result ~= "\n";

    result ~= Colors.blue();
    result ~= "  --> ";
    result ~= Colors.reset();
    result ~= loc.filename;
    result ~= ":";
    result ~= to!string(loc.line);
    result ~= ":";
    result ~= to!string(loc.column);
    result ~= "\n";

    try {
        if (loc.filename.length > 0 && exists(loc.filename)) {
            string source = readText(loc.filename);
            auto lines = source.splitLines();

            if (loc.line > 0 && loc.line <= lines.length) {
                string lineNum = to!string(loc.line);
                string padding = repeat(" ", lineNum.length).join();
                string sourceLine = lines[loc.line - 1];

                result ~= Colors.blue();
                result ~= padding;
                result ~= " |\n";

                result ~= lineNum;
                result ~= " | ";
                result ~= Colors.reset();
                result ~= sourceLine;
                result ~= "\n";

                result ~= Colors.blue();
                result ~= padding;
                result ~= " | ";
                result ~= Colors.cyan();

                uint caretPos = loc.column > 0 ? loc.column - 1 : 0;
                string beforeCaret = "";
                foreach (i, ch; sourceLine) {
                    if (i >= caretPos) break;
                    beforeCaret ~= (ch == '\t') ? '\t' : ' ';
                }
                result ~= beforeCaret;
                result ~= "^";

                if (loc.endOffset > loc.startOffset) {
                    uint extent = loc.endOffset - loc.startOffset;
                    if (extent > 1 && extent < 50) {
                        result ~= repeat("~", extent - 1).join();
                    }
                }

                result ~= Colors.reset();
                result ~= "\n";
            }
        }
    } catch (Exception e) {
        // Couldn't read source, skip context
    }

    return result.data;
}

/**
 * Print a formatted error to stderr
 */
void printError(E)(E exception) if (is(typeof(exception.location) : SourceLocation)) {
    // Extract just the message without location (it's already in exception.msg usually)
    string msg = exception.msg;

    // Strip "Type error: X at file:line:col" pattern to get just X
    auto atIdx = msg.lastIndexOf(" at ");
    if (atIdx > 0) {
        msg = msg[0..atIdx];
    }

    // Strip redundant prefix like "Type error: "
    foreach (prefix; ["Type error: ", "Parse error: ", "Semantic error: "]) {
        if (msg.startsWith(prefix)) {
            msg = msg[prefix.length..$];
            break;
        }
    }

    stderr.write(formatError(typeid(exception).name, msg, exception.location));

    // Print any attached notes (e.g., CTFE evaluation chain)
    static if (is(typeof(exception.notes))) {
        foreach (note; exception.notes) {
            stderr.write(formatNote(note.message, note.location));
        }
    }
}

/**
 * Detect if we're running in a TTY and enable/disable colors
 */
shared static this() {
    import core.sys.posix.unistd : isatty, STDERR_FILENO;
    version(Posix) {
        Colors.enabled = isatty(STDERR_FILENO) != 0;
    } else {
        Colors.enabled = false;
    }
}

unittest {
    auto loc = SourceLocation("test.d", 5, 12, 100, 105);
    auto formatted = formatError("TypeError", "Cannot add 'int' and 'string'", loc);
    assert(formatted.canFind("error"));
    assert(formatted.canFind("test.d:5:12"));
}
