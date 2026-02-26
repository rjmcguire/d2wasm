/**
 * Module representation for multi-module compilation.
 *
 * Each Module represents one compilation unit: a single D source file
 * with its own AST, symbol table, and ModuleScope. Phase tracking
 * allows skipping already-completed work (e.g., on cache hits).
 */
module semantic.module_;

import ast.nodes;
import semantic.symbol_table;

/// Compilation progress of a module.
enum ModulePhase {
    located,            /// file found but not read
    loaded,             /// source read, hash computed
    parsed,             /// parsed into AST
    symbolsCollected,   /// symbols registered in symbol table
    typeChecked,        /// type-checked
}

/**
 * One compilation unit.
 */
class Module {
    /// Fully qualified path: ["animals", "dog"] for `module animals.dog;`
    string[] modulePath;

    /// Absolute path on disk (for error messages and re-reading).
    string sourceFilePath;

    /// Source text (kept for error reporting).
    string sourceText;

    /// Parsed top-level declarations.
    Declaration[] ast;

    /// Per-module symbol table (owns a ModuleScope).
    SymbolTable symbolTable;

    /// Resolved dependency graph (modules this one imports).
    Module[] imports;

    /// AST import nodes (for selective import tracking).
    ImportDecl[] importDecls;

    /// How far along compilation this module is.
    ModulePhase phase;

    /// True for synthetic modules (e.g., runtime/object.d).
    bool isSynthetic;

    /// Fully qualified name as a string: "animals.dog"
    string fullyQualifiedName() const {
        import std.array : join;
        return modulePath.join(".");
    }

    override string toString() const {
        import std.conv : to;
        return "Module(" ~ fullyQualifiedName() ~ ", " ~ phase.to!string ~ ")";
    }
}
