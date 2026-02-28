/**
 * C language parser — wraps CTreeSitterBridge behind the SourceParser interface.
 */
module parser.c_parser;

import parser.source_parser;
import ast.nodes : Declaration;

class CParser : SourceParser {
    Declaration[] parseSourceFile(string filename, string sourceText) {
        import parser.c_tree_sitter_bridge : CTreeSitterBridge;
        auto bridge = new CTreeSitterBridge(filename, sourceText);
        return bridge.parseSourceFile();
    }
}

unittest {
    // CParser parses a trivial C function
    auto parser = new CParser();
    auto decls = parser.parseSourceFile("test.c", "int add(int a, int b) { return a + b; }");
    assert(decls.length == 1, "Expected 1 declaration");
    auto func = cast(FunctionDecl) decls[0];
    assert(func !is null, "Expected FunctionDecl");
    assert(func.name == "add", "Expected function name 'add'");
}

unittest {
    // CParser returns empty array for empty source
    auto parser = new CParser();
    auto decls = parser.parseSourceFile("empty.c", "");
    assert(decls.length == 0, "Expected 0 declarations for empty source");
}

unittest {
    // CParser parses multiple declarations
    auto parser = new CParser();
    auto decls = parser.parseSourceFile("multi.c",
            "int x(int a) { return a; } int y(int b) { return b; }");
    assert(decls.length == 2, "Expected 2 declarations");
}

private import ast.nodes : FunctionDecl;
