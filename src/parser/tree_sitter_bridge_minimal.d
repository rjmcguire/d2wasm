/**
 * Minimal Tree-sitter Bridge - for debugging
 */
module parser.tree_sitter_bridge_minimal;

import ast.nodes;
import ast.statements;
import ast.expressions;
import parser.tree_sitter_c;
import std.string;
import std.conv;
import std.stdio;

/**
 * Parser error with location information
 */
class ParseError : Exception {
    SourceLocation location;
    string hint;
    
    this(string message, SourceLocation location, string hint = "", string file = __FILE__, size_t line = __LINE__) {
        this.location = location;
        this.hint = hint;
        super(format("%s at %s%s", message, location.toString(), hint.length ? ": " ~ hint : ""), file, line);
    }
}

/**
 * Minimal bridge class that converts tree-sitter parse trees to AST
 */
class TreeSitterBridge {
    string filename;
    string sourceText;
    TreeSitterParser parser;
    
    this(string filename, string sourceText) {
        this.filename = filename;
        this.sourceText = sourceText;
        import std.stdio : stderr;
        stderr.writeln("Creating TreeSitterParser in bridge...");
        this.parser = new TreeSitterParser();
        stderr.writeln("TreeSitterParser created successfully.");
    }
    
    /**
     * Parse the source file and return AST declarations
     */
    Declaration[] parseSourceFile() {
        try {
            auto root = parser.parseString(sourceText);
            
            if (!TreeSitterParser.isValid(root)) {
                throw new ParseError("Invalid parse tree root", SourceLocation(filename, 1, 1, 0, 0));
            }
            
            if (TreeSitterParser.hasError(root)) {
                SourceLocation[] errorLocs;
                string[] errorTexts;
                collectParseErrors(root, errorLocs, errorTexts, 7);

                string msg = "Found " ~ to!string(errorLocs.length) ~ " parse error(s):";
                foreach (i, loc; errorLocs) {
                    msg ~= "\n  [" ~ to!string(i + 1) ~ "] line " ~ to!string(loc.line)
                        ~ " col " ~ to!string(loc.column) ~ ": " ~ errorTexts[i];
                }
                throw new ParseError(msg, errorLocs.length > 0 ? errorLocs[0] : SourceLocation(filename, 1, 1, 0, 0));
            }
            
            // Convert tree-sitter parse tree to AST
            return parseSourceFileNode(root);
        } catch (Exception e) {
            throw new ParseError("Parse failed: " ~ e.msg, SourceLocation(filename, 1, 1, 0, 0));
        }
    }
    
    /**
     * Convert a tree-sitter parse tree root to our AST
     */
    Declaration[] parseSourceFileNode(TSNode root) {
        Declaration[] declarations;
        
        uint childCount = TreeSitterParser.getChildCount(root);
        
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(root, i);
            if (!TreeSitterParser.isValid(child)) {
                continue;
            }
            
            string nodeType = TreeSitterParser.getNodeType(child);
            
            try {
                if (nodeType == "function_declaration") {
                    auto decl = parseFunctionDeclaration(child);
                    declarations ~= decl;
                } else if (nodeType != "comment" && nodeType.length > 0) {
                    // Skip unknown nodes for now
                    continue;
                }
            } catch (ParseError e) {
                // Continue parsing other declarations
                continue;
            }
        }
        
        return declarations;
    }
    
    /**
     * Walk the parse tree and collect up to maxErrors error locations.
     * Handles both ERROR nodes (explicit parse errors) and MISSING nodes
     * (where tree-sitter expected a token but didn't find one).
     */
    private void collectParseErrors(TSNode node, ref SourceLocation[] locs, ref string[] texts, int maxErrors) {
        if (locs.length >= maxErrors) return;
        auto childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            if (locs.length >= maxErrors) return;
            auto child = TreeSitterParser.getChild(node, i);
            if (TreeSitterParser.getNodeType(child) == "ERROR") {
                auto point = TreeSitterParser.getStartPoint(child);
                locs ~= SourceLocation(filename, point.row + 1, point.column + 1, 0, 0);
                auto text = TreeSitterParser.getNodeText(child, sourceText);
                auto snippet = text.length > 30 ? text[0..30] ~ "..." : text;
                texts ~= "near '" ~ snippet ~ "'";
            } else if (TreeSitterParser.hasError(child)) {
                bool anyGrandchildHasError = false;
                auto gcCount = TreeSitterParser.getChildCount(child);
                for (uint j = 0; j < gcCount; j++) {
                    auto gc = TreeSitterParser.getChild(child, j);
                    if (TreeSitterParser.hasError(gc)) {
                        anyGrandchildHasError = true;
                        break;
                    }
                }
                if (anyGrandchildHasError) {
                    collectParseErrors(child, locs, texts, maxErrors);
                } else {
                    auto point = TreeSitterParser.getStartPoint(child);
                    locs ~= SourceLocation(filename, point.row + 1, point.column + 1, 0, 0);
                    auto nodeType = TreeSitterParser.getNodeType(child);
                    texts ~= "expected '" ~ nodeType ~ "'";
                }
            }
        }
    }

    /**
     * Parse function declaration (minimal implementation)
     */
    FunctionDecl parseFunctionDeclaration(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        
        // For minimal implementation, create a simple function
        // TODO: Parse actual function structure from tree-sitter
        string name = "parsed_function";
        auto intType = new BasicType(loc, BasicType.Kind.Int32);
        auto returnStmt = new ReturnStatement(loc, LiteralExpression.integer(loc, 42));
        auto body_ = new CompoundStatement(loc, [returnStmt]);
        
        return new FunctionDecl(loc, name, intType, [], body_);
    }
    
    /**
     * Create source location from tree-sitter node
     */
    SourceLocation makeSourceLocation(TSNode node) {
        import parser.tree_sitter_c : ts_node_start_byte, ts_node_end_byte;
        
        auto startPoint = TreeSitterParser.getStartPoint(node);
        auto endPoint = TreeSitterParser.getEndPoint(node);
        
        return SourceLocation(
            filename,
            startPoint.row + 1,
            startPoint.column + 1,
            ts_node_start_byte(node),
            ts_node_end_byte(node)
        );
    }
}