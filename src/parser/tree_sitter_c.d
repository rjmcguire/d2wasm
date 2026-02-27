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
import diagnostic.log : log;

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
    const(char)* ts_node_field_name_for_child(TSNode node, uint32_t index);
    
    // S-expression output (for hashing)
    char* ts_node_string(TSNode node);
    
    // Incremental parsing
    struct TSInputEdit {
        uint32_t start_byte;
        uint32_t old_end_byte;
        uint32_t new_end_byte;
        TSPoint start_point;
        TSPoint old_end_point;
        TSPoint new_end_point;
    }

    void ts_tree_edit(TSTree* tree, const(TSInputEdit)* edit);
    TSTree* ts_tree_copy(TSTree* tree);
    TSRange* ts_tree_get_changed_ranges(
        TSTree* old_tree, TSTree* new_tree, uint32_t* length);

    // Memory management
    void free(void* ptr);  // libc free - ts_node_string returns malloc'd memory

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
        try {
            log(3, "TreeSitterParser constructor started");
            
            log(3, "Creating ts_parser...");
            parser = ts_parser_new();
            if (!parser) {
                throw new Exception("Failed to create tree-sitter parser");
            }
            log(3, "ts_parser created successfully");

            log(3, "Getting D language...");
            auto language = tree_sitter_d();
            if (!language) {
                throw new Exception("Failed to get tree-sitter-d language");
            }
            log(3, "D language obtained successfully");

            log(3, "Setting language...");
            if (!ts_parser_set_language(parser, language)) {
                ts_parser_delete(parser);
                throw new Exception("Failed to set D language for parser");
            }
            log(3, "Language set successfully");
        } catch (Exception e) {
            log(2, "Exception in TreeSitterParser constructor: ", e.msg);
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

    static string getChildFieldName(TSNode node, uint index) {
        const char* fieldName = ts_node_field_name_for_child(node, index);
        return fieldName ? to!string(fieldName) : "";
    }

    static TSPoint getStartPoint(TSNode node) {
        return ts_node_start_point(node);
    }

    static TSPoint getEndPoint(TSNode node) {
        return ts_node_end_point(node);
    }
    
    /**
     * Get S-expression representation of a node (for hashing).
     * Returns the canonical AST structure, whitespace-independent.
     */
    static string getNodeSexp(TSNode node) {
        char* sexp = ts_node_string(node);
        if (sexp is null) return "";
        scope(exit) free(sexp);
        return to!string(sexp);
    }

    // --- Incremental parsing API ---

    /**
     * Apply an edit to the current tree and reparse incrementally.
     * Returns the root node of the new tree. The old tree is replaced.
     *
     * Params:
     *   edit = describes what byte range was replaced
     *   newSource = the full source text after the edit
     *
     * Returns: root node of the new (incrementally parsed) tree
     */
    TSNode reparseIncremental(TSInputEdit edit, string newSource) {
        if (!currentTree)
            throw new Exception("reparseIncremental: no current tree (call parseString first)");

        // Copy old tree so we can compare afterwards
        auto oldTree = ts_tree_copy(currentTree);

        // Apply the edit descriptor to the current tree
        ts_tree_edit(currentTree, &edit);

        // Incremental reparse: tree-sitter reuses unchanged subtrees
        auto newTree = ts_parser_parse_string(
            parser, currentTree, newSource.toStringz(), cast(uint32_t)newSource.length);
        if (!newTree) {
            ts_tree_delete(oldTree);
            throw new Exception("reparseIncremental: incremental parse failed");
        }

        // Replace current tree
        ts_tree_delete(currentTree);
        currentTree = newTree;

        // Clean up old copy (caller can use getChangedRanges before this if needed)
        ts_tree_delete(oldTree);

        return ts_tree_root_node(currentTree);
    }

    /**
     * Get the changed byte ranges between two trees.
     * Typically called between the old tree (before edit) and the new tree (after reparse).
     *
     * Returns: array of TSRange structs describing changed regions.
     */
    static TSRange[] getChangedRanges(TSTree* oldTree, TSTree* newTree) {
        uint32_t rangeCount;
        TSRange* ranges = ts_tree_get_changed_ranges(oldTree, newTree, &rangeCount);
        if (ranges is null || rangeCount == 0)
            return null;

        // Copy into D-managed array
        auto result = new TSRange[rangeCount];
        import core.stdc.string : memcpy;
        memcpy(result.ptr, ranges, rangeCount * TSRange.sizeof);
        free(ranges);
        return result;
    }

    /**
     * Full incremental reparse with change detection.
     * Applies the edit, reparses, and returns changed byte ranges.
     *
     * Params:
     *   edit = describes what byte range was replaced
     *   newSource = the full source text after the edit
     *
     * Returns: array of changed byte ranges (may be empty if parse trees are identical)
     */
    IncrementalParseResult reparseWithChanges(TSInputEdit edit, string newSource) {
        if (!currentTree)
            throw new Exception("reparseWithChanges: no current tree");

        // Keep a copy of the old tree for diffing
        auto oldTree = ts_tree_copy(currentTree);

        // Apply edit to current tree (mutates in place)
        ts_tree_edit(currentTree, &edit);

        // Incremental reparse
        auto newTree = ts_parser_parse_string(
            parser, currentTree, newSource.toStringz(), cast(uint32_t)newSource.length);
        if (!newTree) {
            ts_tree_delete(oldTree);
            throw new Exception("reparseWithChanges: incremental parse failed");
        }

        // Get changed ranges before we lose the old tree
        auto changedRanges = getChangedRanges(oldTree, newTree);

        // Clean up
        ts_tree_delete(oldTree);
        ts_tree_delete(currentTree);
        currentTree = newTree;

        IncrementalParseResult result;
        result.root = ts_tree_root_node(currentTree);
        result.changedRanges = changedRanges;
        return result;
    }
}

/// Result of an incremental reparse operation.
struct IncrementalParseResult {
    TSNode root;            /// Root node of the new parse tree
    TSRange[] changedRanges; /// Byte ranges that changed between old and new tree
}