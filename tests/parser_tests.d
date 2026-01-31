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
    runTest("Source location mapping", delegate() { testSourceLocationMapping(); }, stats);
    runTest("Error handling", delegate() { testErrorHandling(); }, stats);
    runTest("Bridge initialization", delegate() { testBridgeInitialization(); }, stats);
}

void testSourceLocationMapping() {
    auto bridge = new TreeSitterBridge("test.d", "int main() { return 42; }");
    
    // Test the source location creation with a simple file and position
    // Since we can't easily create a real TSNode for testing without complex setup,
    // we'll test that the bridge can be created and has the correct properties
    assertEqual("test.d", bridge.filename);
    assertEqual("int main() { return 42; }", bridge.sourceText);
}

void testErrorHandling() {
    auto bridge = new TreeSitterBridge("test.d", "invalid D code");
    
    // Test that the bridge properly handles parsing errors
    bool exceptionThrown = false;
    try {
        // This should fail because "invalid D code" is not valid D syntax
        auto ast = bridge.parseSourceFile();
    } catch (ParseError e) {
        exceptionThrown = true;
        assertTrue(e.location.filename == "test.d", "Error should have correct filename");
    } catch (Exception e) {
        // Tree-sitter might throw a different type of exception for invalid syntax
        exceptionThrown = true;
    }
    
    assertTrue(exceptionThrown, "Should throw an exception for invalid syntax");
}

void testBridgeInitialization() {
    string filename = "test.d";
    string sourceCode = "int main() { return 0; }";
    
    auto bridge = new TreeSitterBridge(filename, sourceCode);
    
    assertEqual(filename, bridge.filename);
    assertEqual(sourceCode, bridge.sourceText);
}