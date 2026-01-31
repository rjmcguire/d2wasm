/**
 * Parser Tests
 */
module tests.parser_tests;

import std.stdio;
import std.string;
import parser.tree_sitter_bridge;
import parser.tree_sitter_c;
import tests.main;

void runParserTests(ref TestStats stats) {
    runTest("Mock TSNode creation", delegate() { testMockTSNodeCreation(); }, stats);
    runTest("Source location mapping", delegate() { testSourceLocationMapping(); }, stats);
    runTest("Error handling", delegate() { testErrorHandling(); }, stats);
    runTest("Bridge initialization", delegate() { testBridgeInitialization(); }, stats);
}

void testMockTSNodeCreation() {
    // Test the mock TSNode structure
    TSNode node;
    node.nodeType = "function_declaration";
    node.text = "int main()";
    node.startRow = 0;
    node.startColumn = 0;
    node.endRow = 0;
    node.endColumn = 10;
    
    assertTrue(!node.isNull(), "Node should not be null");
    assertTrue(!node.hasError(), "Node should not have error");
    assertEqual("function_declaration", node.nodeType);
    assertEqual("int main()", node.text);
}

void testSourceLocationMapping() {
    auto bridge = new TreeSitterBridge("test.d", "int main() { return 42; }");
    
    TSNode node;
    node.startRow = 2;  // 0-based
    node.startColumn = 4;  // 0-based  
    node.startOffset = 10;
    node.endOffset = 20;
    
    auto loc = bridge.makeSourceLocation(node);
    
    assertEqual("test.d", loc.filename);
    assertEqual(3, loc.line, "Should convert 0-based row to 1-based line");
    assertEqual(5, loc.column, "Should convert 0-based column to 1-based column");
    assertEqual(10, loc.startOffset);
    assertEqual(20, loc.endOffset);
}

void testErrorHandling() {
    auto bridge = new TreeSitterBridge("test.d", "invalid D code");
    
    // Test null node handling
    TSNode nullNode;
    nullNode.isValid = false;
    
    bool exceptionThrown = false;
    try {
        bridge.parseSourceFileNode(nullNode);
    } catch (ParseError e) {
        exceptionThrown = true;
        assertTrue(e.location.filename == "test.d", "Error should have correct filename");
    }
    
    assertTrue(exceptionThrown, "Should throw ParseError for null node");
    
    // Test error node handling
    TSNode errorNode;
    errorNode.nodeType = "ERROR";
    errorNode.isValid = true;
    
    exceptionThrown = false;
    try {
        bridge.parseSourceFileNode(errorNode);
    } catch (ParseError e) {
        exceptionThrown = true;
    }
    
    assertTrue(exceptionThrown, "Should throw ParseError for error node");
}

void testBridgeInitialization() {
    string filename = "test.d";
    string sourceCode = "int main() { return 0; }";
    
    auto bridge = new TreeSitterBridge(filename, sourceCode);
    
    assertEqual(filename, bridge.filename);
    assertEqual(sourceCode, bridge.sourceText);
}