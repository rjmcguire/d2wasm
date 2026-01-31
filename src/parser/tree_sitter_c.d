/**
 * Real tree-sitter C bindings for D-to-WASM Compiler
 * 
 * This module provides the actual interface to the tree-sitter library
 * and the tree-sitter-d grammar.
 */
module parser.tree_sitter_c;

import core.stdc.stdint;
import std.string;
import std.stdio;
import std.conv;

// Tree-sitter C API bindings
extern (C) {
    struct TSNode {
        uint32_t[4] context;
        void* id;
        void* tree;
    }

    struct TSPoint {
        uint32_t row;
        uint32_t column;
    }

    struct TSRange {
        TSPoint start_point;
        TSPoint end_point;
        uint32_t start_byte;
        uint32_t end_byte;
    }

    alias TSParser = void*;
    alias TSTree = void*;
    alias TSLanguage = void*;

    // Core tree-sitter functions
    TSParser* ts_parser_new();
    void ts_parser_delete(TSParser* parser);
    bool ts_parser_set_language(TSParser* parser, TSLanguage* language);
    TSTree* ts_parser_parse_string(TSParser* parser, TSTree* old_tree, const(char)* string, uint32_t length);
    void ts_tree_delete(TSTree* tree);
    TSNode ts_tree_root_node(TSTree* tree);

    // Node functions
    const(char)* ts_node_type(TSNode node);
    uint32_t ts_node_start_byte(TSNode node);
    uint32_t ts_node_end_byte(TSNode node);
    TSPoint ts_node_start_point(TSNode node);
    TSPoint ts_node_end_point(TSNode node);
    uint32_t ts_node_child_count(TSNode node);
    TSNode ts_node_child(TSNode node, uint32_t index);
    TSNode ts_node_child_by_field_name(TSNode node, const(char)* field_name, uint32_t field_name_length);
    bool ts_node_is_null(TSNode node);
    bool ts_node_has_error(TSNode node);

    // Language function - statically linked
    TSLanguage* tree_sitter_d();
}

/**
 * Real tree-sitter parser implementation
 */
class TreeSitterParser {
    private TSParser* parser;
    private TSTree* currentTree;

    this() {
        import std.stdio : writeln;
        
        try {
            writeln("TreeSitterParser constructor started");
            
            writeln("Creating ts_parser...");
            parser = ts_parser_new();
            if (!parser) {
                throw new Exception("Failed to create tree-sitter parser");
            }
            writeln("ts_parser created successfully");

            writeln("Getting D language...");
            auto language = tree_sitter_d();
            if (!language) {
                throw new Exception("Failed to get tree-sitter-d language");
            }
            writeln("D language obtained successfully");

            writeln("Setting language...");
            if (!ts_parser_set_language(parser, language)) {
                ts_parser_delete(parser);
                throw new Exception("Failed to set D language for parser");
            }
            writeln("Language set successfully");
        } catch (Exception e) {
            writeln("Exception in TreeSitterParser constructor: ", e.msg);
            throw e;
        }
    }

    ~this() {
        if (currentTree) {
            ts_tree_delete(currentTree);
        }
        if (parser) {
            ts_parser_delete(parser);
        }
    }

    /**
     * Parse D source code and return the root node
     */
    TSNode parseString(string source) {
        if (currentTree) {
            ts_tree_delete(currentTree);
        }

        currentTree = ts_parser_parse_string(parser, null, source.toStringz(), cast(uint32_t)source.length);
        if (!currentTree) {
            throw new Exception("Failed to parse source code");
        }

        return ts_tree_root_node(currentTree);
    }

    /**
     * Static utility functions for node manipulation
     */
    static bool isValid(TSNode node) {
        return !ts_node_is_null(node);
    }

    static bool hasError(TSNode node) {
        return ts_node_has_error(node);
    }

    static string getNodeType(TSNode node) {
        const char* typeStr = ts_node_type(node);
        return typeStr ? to!string(typeStr) : "";
    }

    static string getNodeText(TSNode node, string source) {
        uint32_t startByte = ts_node_start_byte(node);
        uint32_t endByte = ts_node_end_byte(node);
        
        if (startByte < source.length && endByte <= source.length && startByte < endByte) {
            return source[startByte..endByte];
        }
        return "";
    }

    static uint getChildCount(TSNode node) {
        return ts_node_child_count(node);
    }

    static TSNode getChild(TSNode node, uint index) {
        return ts_node_child(node, index);
    }

    static TSNode getChildByFieldName(TSNode node, string fieldName) {
        return ts_node_child_by_field_name(node, fieldName.toStringz(), cast(uint32_t)fieldName.length);
    }

    static TSPoint getStartPoint(TSNode node) {
        return ts_node_start_point(node);
    }

    static TSPoint getEndPoint(TSNode node) {
        return ts_node_end_point(node);
    }
}