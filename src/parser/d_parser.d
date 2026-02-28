/**
 * D language parser — wraps TreeSitterBridge behind the SourceParser interface.
 */
module parser.d_parser;

import parser.source_parser;
import ast.nodes : Declaration;

class DParser : SourceParser {
    Declaration[] parseSourceFile(string filename, string sourceText) {
        import parser.tree_sitter_bridge : TreeSitterBridge;
        auto bridge = new TreeSitterBridge(filename, sourceText);
        return bridge.parseSourceFile();
    }
}

unittest {
    // DParser parses a trivial function and returns declarations
    auto parser = new DParser();
    auto decls = parser.parseSourceFile("test.d", "int add(int a, int b) { return a + b; }");
    assert(decls.length == 1, "Expected 1 declaration");
    auto func = cast(FunctionDecl)decls[0];
    assert(func !is null, "Expected FunctionDecl");
    assert(func.name == "add", "Expected function name 'add'");
}

unittest {
    // DParser returns empty array for empty source
    auto parser = new DParser();
    auto decls = parser.parseSourceFile("empty.d", "");
    assert(decls.length == 0, "Expected 0 declarations for empty source");
}

unittest {
    // DParser parses multiple declarations
    auto parser = new DParser();
    auto decls = parser.parseSourceFile("multi.d", "int x() { return 1; } int y() { return 2; }");
    assert(decls.length == 2, "Expected 2 declarations");
}

unittest {
    // ParseFn delegate from DParser works identically
    import parser.source_parser : ParseFn;
    auto parser = new DParser();
    ParseFn fn = (string f, string s) => parser.parseSourceFile(f, s);
    auto decls = fn("delegate.d", "int foo() { return 42; }");
    assert(decls.length == 1);
    assert((cast(FunctionDecl)decls[0]).name == "foo");
}

private import ast.nodes : FunctionDecl;
