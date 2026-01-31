/**
 * Mock tree-sitter implementation for Phase 2 testing
 * 
 * This module provides a mock tree-sitter interface that allows us to test
 * the rest of the compiler pipeline without requiring the actual tree-sitter
 * library compilation. In Phase 3, this will be replaced with real bindings.
 */
module parser.tree_sitter_c;

import core.stdc.stdint;
import std.string;

// Mock TSNode structure
struct TSNode {
    string nodeType;
    string text;
    TSNode*[] children;
    uint32_t startOffset;
    uint32_t endOffset;
    uint32_t startRow;
    uint32_t startColumn;
    uint32_t endRow;
    uint32_t endColumn;
    bool isValid = true;
    
    bool isNull() const {
        return !isValid || nodeType.length == 0;
    }
    
    bool hasError() const {
        return nodeType == "ERROR";
    }
}

struct TSPoint {
    uint32_t row;
    uint32_t column;
}

/**
 * Mock tree-sitter parser for Phase 2 testing
 */
class TreeSitterParser {
    this() {
        // Mock implementation - no actual initialization needed
    }
    
    /**
     * Parse D source code and return a mock root node
     */
    TSNode parseString(string source) {
        // For now, create a simple mock parse tree for basic D programs
        return createMockParseTree(source);
    }
    
    /**
     * Create a mock parse tree for simple D programs
     */
    private TSNode createMockParseTree(string source) {
        TSNode root;
        root.nodeType = "source_file";
        root.text = source;
        root.isValid = true;
        root.startOffset = 0;
        root.endOffset = cast(uint32_t)source.length;
        root.startRow = 0;
        root.startColumn = 0;
        
        // Simple pattern matching to find D functions
        import std.regex;
        import std.array;
        
        // Match function declarations: type name(params) { ... }
        auto functionRegex = regex(r"(\w+)\s+(\w+)\s*\([^)]*\)\s*\{", "g");
        auto matches = matchAll(source, functionRegex);
        
        foreach (match; matches) {
            auto funcNode = new TSNode;
            funcNode.nodeType = "function_declaration";
            funcNode.text = match.hit;
            funcNode.isValid = true;
            funcNode.startOffset = cast(uint32_t)match.pre.length;
            funcNode.endOffset = cast(uint32_t)(match.pre.length + match.hit.length);
            
            // Create mock child nodes for name, return type, etc.
            auto nameNode = new TSNode;
            nameNode.nodeType = "name";
            nameNode.text = match[2];  // function name
            nameNode.isValid = true;
            nameNode.startOffset = funcNode.startOffset + cast(uint32_t)match.pre.length;
            nameNode.endOffset = nameNode.startOffset + cast(uint32_t)match[2].length;
            funcNode.children ~= nameNode;
            
            auto retTypeNode = new TSNode;
            retTypeNode.nodeType = "return_type";  
            retTypeNode.text = match[1];  // return type
            retTypeNode.isValid = true;
            retTypeNode.startOffset = funcNode.startOffset;
            retTypeNode.endOffset = retTypeNode.startOffset + cast(uint32_t)match[1].length;
            funcNode.children ~= retTypeNode;
            
            root.children ~= funcNode;
        }
        
        return root;
    }
    
    /**
     * Static utility functions for node manipulation
     */
    static bool isValid(TSNode node) {
        return node.isValid && !node.isNull();
    }
    
    static bool hasError(TSNode node) {
        return node.hasError();
    }
    
    static string getNodeType(TSNode node) {
        return node.nodeType;
    }
    
    static string getNodeText(TSNode node, string source) {
        if (node.startOffset < source.length && node.endOffset <= source.length && node.startOffset < node.endOffset) {
            return source[node.startOffset..node.endOffset];
        }
        return node.text;  // fallback to stored text
    }
    
    static uint getChildCount(TSNode node) {
        return cast(uint)node.children.length;
    }
    
    static TSNode getChild(TSNode node, uint index) {
        if (index >= node.children.length) {
            TSNode nullNode;
            nullNode.isValid = false;
            return nullNode;
        }
        return *node.children[index];
    }
    
    static TSNode getChildByFieldName(TSNode node, string fieldName) {
        // Mock field access - find child by node type matching field name
        foreach (child; node.children) {
            if (child.nodeType == fieldName) {
                return *child;
            }
        }
        
        TSNode nullNode;
        nullNode.isValid = false;
        return nullNode;
    }
    
    static TSPoint getStartPoint(TSNode node) {
        TSPoint point;
        point.row = node.startRow;
        point.column = node.startColumn;
        return point;
    }
    
    static TSPoint getEndPoint(TSNode node) {
        TSPoint point;
        point.row = node.endRow;
        point.column = node.endColumn;
        return point;
    }
}