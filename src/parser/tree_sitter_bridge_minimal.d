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
        writeln("Creating TreeSitterParser in bridge...");
        this.parser = new TreeSitterParser();
        writeln("TreeSitterParser created successfully.");
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
                throw new ParseError("Parse errors in source file", SourceLocation(filename, 1, 1, 0, 0));
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