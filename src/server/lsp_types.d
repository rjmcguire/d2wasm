/**
 * LSP Type Definitions
 *
 * Minimal LSP types needed for the D-to-WASM compiler's language server.
 */
module server.lsp_types;

import std.json;

/// LSP Position (0-based line and character)
struct Position {
    uint line;
    uint character;

    JSONValue toJSON() const {
        JSONValue j;
        j["line"] = line;
        j["character"] = character;
        return j;
    }

    static Position fromJSON(JSONValue j) {
        return Position(
            cast(uint)j["line"].get!long,
            cast(uint)j["character"].get!long
        );
    }
}

/// LSP Range
struct Range {
    Position start;
    Position end;

    JSONValue toJSON() const {
        JSONValue j;
        j["start"] = start.toJSON();
        j["end"] = end.toJSON();
        return j;
    }

    static Range fromJSON(JSONValue j) {
        return Range(Position.fromJSON(j["start"]), Position.fromJSON(j["end"]));
    }
}

/// LSP Location (URI + Range)
struct Location {
    string uri;
    Range range;

    JSONValue toJSON() const {
        JSONValue j;
        j["uri"] = uri;
        j["range"] = range.toJSON();
        return j;
    }
}

/// LSP Diagnostic severity
enum DiagnosticSeverity : int {
    Error = 1,
    Warning = 2,
    Information = 3,
    Hint = 4
}

/// LSP Diagnostic
struct Diagnostic {
    Range range;
    DiagnosticSeverity severity;
    string message;
    string source = "d2wasm";

    JSONValue toJSON() const {
        JSONValue j;
        j["range"] = range.toJSON();
        j["severity"] = cast(int)severity;
        j["message"] = message;
        j["source"] = source;
        return j;
    }
}

/// LSP SymbolKind
enum LSPSymbolKind : int {
    File = 1,
    Module = 2,
    Namespace = 3,
    Package = 4,
    Class = 5,
    Method = 6,
    Property = 7,
    Field = 8,
    Constructor = 9,
    Enum = 10,
    Interface = 11,
    Function = 12,
    Variable = 13,
    Constant = 14,
    String = 15,
    Number = 16,
    Boolean = 17,
    Array = 18,
    Object = 19,
    Key = 20,
    Null = 21,
    EnumMember = 22,
    Struct = 23,
    Event = 24,
    Operator = 25,
    TypeParameter = 26
}

/// LSP CompletionItemKind
enum CompletionItemKind : int {
    Text = 1,
    Method = 2,
    Function = 3,
    Constructor = 4,
    Field = 5,
    Variable = 6,
    Class = 7,
    Interface = 8,
    Module = 9,
    Property = 10,
    Unit = 11,
    Value = 12,
    Enum = 13,
    Keyword = 14,
    Snippet = 15,
    Color = 16,
    File = 17,
    Reference = 18,
    Folder = 19,
    EnumMember = 20,
    Constant = 21,
    Struct = 22,
    Event = 23,
    Operator = 24,
    TypeParameter = 25
}

/// Convert file path to URI
string pathToURI(string path) {
    import std.path : absolutePath;
    return "file://" ~ absolutePath(path);
}

/// Convert URI to file path
string uriToPath(string uri) {
    if (uri.length > 7 && uri[0 .. 7] == "file://")
        return uri[7 .. $];
    return uri;
}

/// Convert SourceLocation to LSP Range
Range sourceLocationToRange(uint startOffset, uint endOffset, string sourceText) {
    // Convert byte offsets to line/character
    uint startLine, startChar, endLine, endChar;

    uint line, col;
    foreach (i, c; sourceText) {
        if (i == startOffset) {
            startLine = line;
            startChar = col;
        }
        if (i == endOffset) {
            endLine = line;
            endChar = col;
        }
        if (c == '\n') {
            line++;
            col = 0;
        } else {
            col++;
        }
    }
    if (endOffset >= sourceText.length) {
        endLine = line;
        endChar = col;
    }

    return Range(Position(startLine, startChar), Position(endLine, endChar));
}

/// Convert line/character to byte offset
uint positionToByteOffset(Position pos, string sourceText) {
    uint line, col, offset;
    foreach (i, c; sourceText) {
        if (line == pos.line && col == pos.character)
            return cast(uint)i;
        if (c == '\n') {
            line++;
            col = 0;
        } else {
            col++;
        }
    }
    return cast(uint)sourceText.length;
}
