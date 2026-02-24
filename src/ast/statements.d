/**
 * AST Statement Nodes for D-to-WASM Compiler
 * 
 * This module contains all statement AST node implementations.
 */
module ast.statements;

import ast.nodes;
import ast.expressions;
import std.string;
import std.conv;

// ===== STATEMENTS =====

/**
 * Compound statement: { statements }
 */
class CompoundStatement : Statement {
    Statement[] statements;
    
    // Assigned by type checker - local IDs to destruct when exiting this scope
    // Order is construction order; destruct in reverse
    uint[] destructOnExit;
    
    this(SourceLocation loc, Statement[] statements) {
        super(loc);
        this.statements = statements;
    }
    
    
    override string toString() const {
        return format("CompoundStatement(%d statements)", statements.length);
    }
}

/**
 * If statement: if (condition) thenStmt else elseStmt
 */
class IfStatement : Statement {
    Expression condition;
    Statement thenStatement;
    Statement elseStatement;  // null if no else
    
    this(SourceLocation loc, Expression condition, 
         Statement thenStatement, Statement elseStatement = null) {
        super(loc);
        this.condition = condition;
        this.thenStatement = thenStatement;
        this.elseStatement = elseStatement;
    }
    
    
    override string toString() const {
        return "IfStatement";
    }
}

/**
 * While statement: while (condition) body
 */
class WhileStatement : Statement {
    Expression condition;
    Statement body_;
    
    this(SourceLocation loc, Expression condition, Statement body_) {
        super(loc);
        this.condition = condition;
        this.body_ = body_;
    }
    
    
    override string toString() const {
        return "WhileStatement";
    }
}

/**
 * For statement: for (init; condition; update) body
 */
class ForStatement : Statement {
    Statement init;       // Can be variable declaration or expression statement
    Expression condition; // null means infinite loop
    Expression update;    // null if no update
    Statement body_;
    
    this(SourceLocation loc, Statement init, Expression condition, 
         Expression update, Statement body_) {
        super(loc);
        this.init = init;
        this.condition = condition;
        this.update = update;
        this.body_ = body_;
    }
    
    
    override string toString() const {
        return "ForStatement";
    }
}

/**
 * Return statement: return expression;
 */
class ReturnStatement : Statement {
    Expression value;  // null for void return
    
    // Assigned by type checker - destruction lists for each scope we're exiting
    // unwindChain[0] is the innermost scope, [n-1] is the function scope
    // Each entry contains local IDs to destruct (in construction order; reverse for destruction)
    uint[][] unwindChain;
    
    this(SourceLocation loc, Expression value = null) {
        super(loc);
        this.value = value;
    }
    
    
    override string toString() const {
        if (value) {
            return format("ReturnStatement(%s)", value.toString());
        }
        return "ReturnStatement(void)";
    }
}

/**
 * Expression statement: expression;
 */
class ExpressionStatement : Statement {
    Expression expression;
    
    this(SourceLocation loc, Expression expression) {
        super(loc);
        this.expression = expression;
    }
    
    
    override string toString() const {
        return format("ExpressionStatement(%s)", expression.toString());
    }
}

/**
 * Variable declaration statement: type name = initializer;
 * Used for local variable declarations inside function bodies.
 */
class VariableDeclarationStatement : Statement {
    string name;
    Type type;
    Expression initializer;  // null if no initializer
    
    // Assigned by type checker - unique ID for this local variable
    uint uniqueLocalId = uint.max;  // uint.max = unassigned
    bool needsDestruction = false;  // Has destructor that needs calling
    bool isCaptured;  // true if captured by a delegate/lambda
    
    this(SourceLocation loc, string name, Type type, Expression initializer = null) {
        super(loc);
        this.name = name;
        this.type = type;
        this.initializer = initializer;
    }
    
    override string toString() const {
        if (initializer) {
            return format("VariableDeclarationStatement(%s %s = %s)", type.toString(), name, initializer.toString());
        }
        return format("VariableDeclarationStatement(%s %s)", type.toString(), name);
    }
}

/**
 * Mixin statement: mixin(expression);
 * Used for mixins inside function bodies.
 * The expression must evaluate to a string at compile time.
 * After expansion, expandedStatements contains the parsed statements.
 */
class MixinStatement : Statement {
    Expression mixinExpr;          // The expression that produces the string
    Statement[] expandedStatements; // Filled after expansion
    bool isExpanded;               // Whether expansion has been performed
    
    this(SourceLocation loc, Expression mixinExpr) {
        super(loc);
        this.mixinExpr = mixinExpr;
        this.isExpanded = false;
    }
    
    override string toString() const {
        if (isExpanded) {
            return format("MixinStatement(expanded: %d statements)", expandedStatements.length);
        }
        return format("MixinStatement(%s)", mixinExpr.toString());
    }
}

/**
 * Struct declaration as a statement (inner struct inside a function body).
 * Wraps a StructDecl so it can appear in statement position.
 */
class StructDeclarationStatement : Statement {
    StructDecl structDecl;

    this(SourceLocation loc, StructDecl structDecl) {
        super(loc);
        this.structDecl = structDecl;
    }

    override string toString() const {
        return format("StructDeclarationStatement(%s)", structDecl.name);
    }
}

/**
 * Break statement: break;
 * Exits the innermost enclosing loop.
 */
class BreakStatement : Statement {
    this(SourceLocation loc) {
        super(loc);
    }

    override string toString() const {
        return "BreakStatement";
    }
}

/**
 * Continue statement: continue;
 * Skips to the next iteration of the innermost enclosing loop.
 */
class ContinueStatement : Statement {
    this(SourceLocation loc) {
        super(loc);
    }

    override string toString() const {
        return "ContinueStatement";
    }
}

/**
 * Try statement: try { body } catch (Type e) { handler } finally { cleanup }
 */
class TryStatement : Statement {
    Statement tryBody;
    CatchClause[] catches;
    Statement finallyBody;  // null if no finally

    this(SourceLocation loc, Statement tryBody, CatchClause[] catches, Statement finallyBody) {
        super(loc);
        this.tryBody = tryBody;
        this.catches = catches;
        this.finallyBody = finallyBody;
    }

    override string toString() const {
        return format("TryStatement(%d catches)", catches.length);
    }
}

/**
 * Catch clause within a try statement
 */
class CatchClause {
    SourceLocation location;
    Type exceptionType;    // null for catch-all
    string paramName;      // null if no binding
    Statement body_;

    this(SourceLocation loc, Type exceptionType, string paramName, Statement body_) {
        this.location = loc;
        this.exceptionType = exceptionType;
        this.paramName = paramName;
        this.body_ = body_;
    }
}