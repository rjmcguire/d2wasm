/**
 * Shared error kind enum for both WASM and native CTFE backends.
 * Used in exception slots and trap reporting.
 */
module codegen.error_kind;

enum ErrorKind : uint {
    None = 0,
    DivByZero = 1,
    ModByZero = 2,
    UserThrow = 3,
    NullDeref = 4,
    OutOfBounds = 5,
    OutOfMemory = 6,
    Overflow = 7,
}

/// Map error kind to a human-readable message.
string errorKindMessage(ErrorKind kind) {
    final switch (kind) {
        case ErrorKind.None: return "no error";
        case ErrorKind.DivByZero: return "integer divide by zero";
        case ErrorKind.ModByZero: return "integer modulo by zero";
        case ErrorKind.UserThrow: return "uncaught exception";
        case ErrorKind.NullDeref: return "null pointer dereference";
        case ErrorKind.OutOfBounds: return "array index out of bounds";
        case ErrorKind.OutOfMemory: return "CTFE out of memory";
        case ErrorKind.Overflow: return "integer overflow";
    }
}
