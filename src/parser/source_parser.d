/**
 * Language-agnostic parser interface for the compiler pipeline.
 *
 * All consumers that need to parse source text (mixin expansion, template
 * re-parsing, import resolution) use the `ParseFn` delegate type defined
 * here.  Concrete implementations (e.g. `DParser`) implement `SourceParser`.
 */
module parser.source_parser;

import ast.nodes : Declaration;

/// Delegate type used throughout the pipeline for on-demand parsing.
alias ParseFn = Declaration[] delegate(string filename, string sourceText);

/// Language-agnostic parser interface.
interface SourceParser {
    Declaration[] parseSourceFile(string filename, string sourceText);
}

unittest {
    // ParseFn delegate can be created from a SourceParser
    import parser.d_parser : DParser;
    SourceParser sp = new DParser();
    ParseFn fn = (string f, string s) => sp.parseSourceFile(f, s);
    assert(fn !is null);
}
