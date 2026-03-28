/**
 * Warning Accumulator
 *
 * Non-fatal diagnostics collected during compilation. Unlike errors (which
 * throw exceptions and halt), warnings are accumulated and reported after
 * compilation completes.
 */
module diagnostic.warnings;

import ast.nodes : SourceLocation;

/// Severity levels (matches LSP DiagnosticSeverity values)
enum WarningSeverity : int {
    Error = 1,
    Warning = 2,
    Information = 3,
    Hint = 4
}

/// A single warning diagnostic
struct Warning {
    string message;
    SourceLocation location;
    WarningSeverity severity = WarningSeverity.Warning;
}

/**
 * Thread-local warning accumulator. Set before compilation, read after.
 * Null when not in LSP mode (no-op overhead).
 */
Warning[]* warningsSink;

/// Emit a warning into the current sink (no-op if sink is null)
void emitWarning(string message, SourceLocation location,
    WarningSeverity severity = WarningSeverity.Warning)
{
    if (warningsSink !is null)
        *warningsSink ~= Warning(message, location, severity);
}
