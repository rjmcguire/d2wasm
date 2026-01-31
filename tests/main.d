/**
 * Test runner for D-to-WASM Compiler
 * 
 * This program runs all unit tests and integration tests for the compiler.
 */
module tests.main;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.string;

import tests.ast_tests;
import tests.parser_tests;
import tests.feature_validator_tests;
import tests.integration_tests;

/**
 * Test statistics
 */
struct TestStats {
    int totalTests = 0;
    int passedTests = 0;
    int failedTests = 0;
    
    void recordPass() { totalTests++; passedTests++; }
    void recordFail() { totalTests++; failedTests++; }
    
    void printSummary() {
        writeln("\n=== TEST SUMMARY ===");
        writefln("Total Tests: %d", totalTests);
        writefln("Passed: %d", passedTests);
        writefln("Failed: %d", failedTests);
        writefln("Success Rate: %.1f%%", 
            totalTests > 0 ? (cast(double)passedTests / totalTests * 100.0) : 0.0);
    }
    
    bool allPassed() const {
        return failedTests == 0 && totalTests > 0;
    }
}

int main(string[] args) {
    writeln("D-to-WASM Compiler Test Suite");
    writeln("============================\n");
    
    TestStats stats;
    
    try {
        // Run unit tests
        writeln("Running AST tests...");
        runAstTests(stats);
        
        writeln("Running parser tests...");
        runParserTests(stats);
        
        writeln("Running feature validator tests...");
        runFeatureValidatorTests(stats);
        
        // Run integration tests
        writeln("Running integration tests...");
        runIntegrationTests(stats);
        
        stats.printSummary();
        
        return stats.allPassed() ? 0 : 1;
        
    } catch (Exception e) {
        writeln("Test runner error: ", e.msg);
        return 1;
    }
}

/**
 * Helper function to run a test and record results
 */
void runTest(string testName, void delegate() testFunc, ref TestStats stats) {
    try {
        testFunc();
        writefln("  ✅ %s", testName);
        stats.recordPass();
    } catch (Exception e) {
        writefln("  ❌ %s: %s", testName, e.msg);
        stats.recordFail();
    }
}

/**
 * Helper function to assert conditions in tests
 */
void assertTrue(bool condition, string message, string file = __FILE__, size_t line = __LINE__) {
    if (!condition) {
        throw new Exception("Assertion failed: " ~ message, file, line);
    }
}

void assertEqual(T)(T expected, T actual, string message = "", string file = __FILE__, size_t line = __LINE__) {
    if (expected != actual) {
        string fullMessage = format("Expected %s, got %s", expected, actual);
        if (message.length) {
            fullMessage = message ~ ": " ~ fullMessage;
        }
        throw new Exception(fullMessage, file, line);
    }
}

void assertNotNull(T)(T value, string message = "Value should not be null", string file = __FILE__, size_t line = __LINE__) {
    if (value is null) {
        throw new Exception(message, file, line);
    }
}