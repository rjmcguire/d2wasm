/**
 * Feature Validator Tests
 */
module tests.feature_validator_tests;

import std.stdio;
import std.string;
import std.algorithm;
import ast.nodes;
import ast.statements; 
import ast.expressions;
import semantic.feature_validator;
import tests.main;

void runFeatureValidatorTests(ref TestStats stats) {
    runTest("Valid function passes", delegate() { testValidFunctionPasses(); }, stats);
    runTest("Template function rejected", delegate() { testTemplateFunctionRejected(); }, stats);
    runTest("GC new operator rejected", delegate() { testNewOperatorRejected(); }, stats);
    runTest("Invalid attributes rejected", delegate() { testInvalidAttributesRejected(); }, stats);
    runTest("Forbidden identifiers rejected", delegate() { testForbiddenIdentifiersRejected(); }, stats);
    runTest("Template class rejected", delegate() { testTemplateClassRejected(); }, stats);
}

void testValidFunctionPasses() {
    auto validator = new FeatureValidator();
    auto loc = SourceLocation("test.d", 1, 1, 0, 20);
    
    // Create valid function
    auto returnType = new BasicType(loc, BasicType.Kind.Int32);
    auto returnStmt = new ReturnStatement(loc, LiteralExpression.integer(loc, 42));
    auto body_ = new CompoundStatement(loc, [returnStmt]);
    auto func = new FunctionDecl(loc, "validFunction", returnType, [], body_, ["@safe"]);
    
    // Should not throw
    validator.validateSourceFile([func]);
}

void testTemplateFunctionRejected() {
    auto validator = new FeatureValidator();
    auto loc = SourceLocation("test.d", 1, 1, 0, 30);
    
    // Create template function (name contains template syntax)
    auto returnType = new BasicType(loc, BasicType.Kind.Int32);
    auto returnStmt = new ReturnStatement(loc, LiteralExpression.integer(loc, 42));
    auto body_ = new CompoundStatement(loc, [returnStmt]);
    auto func = new FunctionDecl(loc, "templateFunc!int", returnType, [], body_);
    
    bool exceptionThrown = false;
    try {
        validator.validateSourceFile([func]);
    } catch (FeatureValidationError e) {
        exceptionThrown = true;
        assertTrue(e.msg.canFind("Template functions are not supported"), 
                  "Should have correct error message");
    }
    
    assertTrue(exceptionThrown, "Should reject template function");
}

void testNewOperatorRejected() {
    auto validator = new FeatureValidator();
    auto loc = SourceLocation("test.d", 1, 1, 0, 15);
    
    // Create function call to 'new' (GC allocation)
    auto newIdentifier = new IdentifierExpression(loc, "new");
    auto newCall = new CallExpression(loc, newIdentifier, []);
    auto exprStmt = new ExpressionStatement(loc, newCall);
    auto body_ = new CompoundStatement(loc, [exprStmt]);
    
    auto returnType = new BasicType(loc, BasicType.Kind.Void);
    auto func = new FunctionDecl(loc, "testFunc", returnType, [], body_);
    
    bool exceptionThrown = false;
    try {
        validator.validateSourceFile([func]);
    } catch (FeatureValidationError e) {
        exceptionThrown = true;
        assertTrue(e.msg.canFind("'new' operator is not supported"), 
                  "Should have correct error message");
    }
    
    assertTrue(exceptionThrown, "Should reject new operator");
}

void testInvalidAttributesRejected() {
    auto validator = new FeatureValidator();
    auto loc = SourceLocation("test.d", 1, 1, 0, 25);
    
    // Create function with unsupported attribute
    auto returnType = new BasicType(loc, BasicType.Kind.Int32);
    auto returnStmt = new ReturnStatement(loc, LiteralExpression.integer(loc, 42));
    auto body_ = new CompoundStatement(loc, [returnStmt]);
    auto func = new FunctionDecl(loc, "testFunc", returnType, [], body_, ["@property"]);
    
    bool exceptionThrown = false;
    try {
        validator.validateSourceFile([func]);
    } catch (FeatureValidationError e) {
        exceptionThrown = true;
        assertTrue(e.msg.canFind("@property"), "Should mention rejected attribute");
    }
    
    assertTrue(exceptionThrown, "Should reject unsupported attribute");
}

void testForbiddenIdentifiersRejected() {
    auto validator = new FeatureValidator();
    auto loc = SourceLocation("test.d", 1, 1, 0, 10);
    
    // Create expression using forbidden identifier
    auto importIdent = new IdentifierExpression(loc, "import");
    auto exprStmt = new ExpressionStatement(loc, importIdent);
    auto body_ = new CompoundStatement(loc, [exprStmt]);
    
    auto returnType = new BasicType(loc, BasicType.Kind.Void);
    auto func = new FunctionDecl(loc, "testFunc", returnType, [], body_);
    
    bool exceptionThrown = false;
    try {
        validator.validateSourceFile([func]);
    } catch (FeatureValidationError e) {
        exceptionThrown = true;
        assertTrue(e.msg.canFind("'import' refers to an unsupported feature"), 
                  "Should have correct error message");
    }
    
    assertTrue(exceptionThrown, "Should reject forbidden identifier");
}

void testTemplateClassRejected() {
    auto validator = new FeatureValidator();
    auto loc = SourceLocation("test.d", 1, 1, 0, 20);
    
    // Create template class (name contains template syntax)
    auto classDecl = new ClassDecl(loc, "Vector!T", null, [], []);
    
    bool exceptionThrown = false;
    try {
        validator.validateSourceFile([classDecl]);
    } catch (FeatureValidationError e) {
        exceptionThrown = true;
        assertTrue(e.msg.canFind("Template classes are not supported"), 
                  "Should have correct error message");
    }
    
    assertTrue(exceptionThrown, "Should reject template class");
}