/**
 * AST Node Tests
 */
module tests.ast_tests;

import std.stdio;
import std.string;
import ast.nodes;
import ast.statements;
import ast.expressions;
import tests.main;

void runAstTests(ref TestStats stats) {
    runTest("Basic type creation", delegate() { testBasicTypeCreation(); }, stats);
    runTest("Function declaration", delegate() { testFunctionDeclaration(); }, stats);
    runTest("Class declaration", delegate() { testClassDeclaration(); }, stats);
    runTest("Binary expression", delegate() { testBinaryExpression(); }, stats);
    runTest("Literal expression", delegate() { testLiteralExpression(); }, stats);
    runTest("Source location", delegate() { testSourceLocation(); }, stats);
}

void testBasicTypeCreation() {
    auto loc = SourceLocation("test.d", 1, 1, 0, 3);
    
    // Test integer type
    auto intType = new BasicType(loc, BasicType.Kind.Int32);
    assertTrue(intType.isBasicType(), "Should be basic type");
    assertTrue(!intType.isPointer(), "Should not be pointer");
    assertEqual(4, intType.size(), "Int32 should be 4 bytes");
    assertEqual("int", intType.toString(), "Should have correct string representation");
    
    // Test void type  
    auto voidType = new BasicType(loc, BasicType.Kind.Void);
    assertEqual(0, voidType.size(), "Void should be 0 bytes");
    assertEqual("void", voidType.toString(), "Should have correct string representation");
}

void testFunctionDeclaration() {
    auto loc = SourceLocation("test.d", 1, 1, 0, 20);
    
    // Create return type
    auto returnType = new BasicType(loc, BasicType.Kind.Int32);
    
    // Create parameters
    auto paramType = new BasicType(loc, BasicType.Kind.Int32);
    Parameter[] params = [Parameter(paramType, "x", null)];
    
    // Create body
    auto returnStmt = new ReturnStatement(loc, LiteralExpression.integer(loc, 42));
    auto body_ = new CompoundStatement(loc, [returnStmt]);
    
    // Create function
    auto func = new FunctionDecl(loc, "test", returnType, params, body_);
    
    assertEqual("test", func.name, "Function should have correct name");
    assertEqual(1, func.parameters.length, "Should have one parameter");
    assertEqual("x", func.parameters[0].name, "Parameter should have correct name");
    assertNotNull(func.body_, "Should have body");
}

void testClassDeclaration() {
    auto loc = SourceLocation("test.d", 1, 1, 0, 15);
    
    // Create empty class
    auto classDecl = new ClassDecl(loc, "TestClass", null, [], []);
    
    assertEqual("TestClass", classDecl.name, "Class should have correct name");
    assertTrue(classDecl.baseClass is null, "Should have no base class");
    assertEqual(0, classDecl.interfaces.length, "Should have no interfaces");
    assertEqual(0, classDecl.members.length, "Should have no members");
}

void testBinaryExpression() {
    auto loc = SourceLocation("test.d", 1, 1, 0, 5);
    
    auto left = LiteralExpression.integer(loc, 10);
    auto right = LiteralExpression.integer(loc, 5);
    auto binExpr = new BinaryExpression(loc, left, BinaryExpression.Operator.Add, right);
    
    assertTrue(binExpr.isConstant(), "Binary expression with constant operands should be constant");
    assertTrue(!binExpr.hasLValue(), "Binary expressions should not have lvalue");
    assertEqual("(10 + 5)", binExpr.toString(), "Should have correct string representation");
}

void testLiteralExpression() {
    auto loc = SourceLocation("test.d", 1, 1, 0, 2);
    
    // Integer literal
    auto intLit = LiteralExpression.integer(loc, 42);
    assertTrue(intLit.isConstant(), "Literal should be constant");
    assertTrue(!intLit.hasLValue(), "Literal should not have lvalue");
    assertEqual("42", intLit.toString(), "Should have correct string representation");
    
    // String literal
    auto strLit = LiteralExpression.string_(loc, "hello");
    assertTrue(strLit.isConstant(), "String literal should be constant");
    assertEqual(`"hello"`, strLit.toString(), "Should include quotes in string representation");
    
    // Boolean literal
    auto boolLit = LiteralExpression.boolean(loc, true);
    assertTrue(boolLit.isConstant(), "Boolean literal should be constant");
    assertEqual("true", boolLit.toString(), "Should have correct boolean representation");
}

void testSourceLocation() {
    auto loc = SourceLocation("test.d", 10, 5, 100, 110);
    
    assertEqual("test.d", loc.filename);
    assertEqual(10, loc.line);
    assertEqual(5, loc.column);
    assertEqual(100, loc.startOffset);
    assertEqual(110, loc.endOffset);
    assertEqual("test.d:10:5", loc.toString(), "Should format correctly");
}