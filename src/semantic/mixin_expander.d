/**
 * Mixin and Static If Expansion for D-to-WASM Compiler
 * 
 * This module handles the expansion of mixin declarations and static if.
 * It evaluates expressions at compile time and manipulates the AST.
 * 
 * Supports:
 * - Module-level mixins (expand to declarations)
 * - Function-level mixins (expand to statements)
 * - Static if (compile-time conditional compilation)
 */
module semantic.mixin_expander;

import ast.nodes;
import ast.statements;
import ast.expressions;
import parser.tree_sitter_bridge;
import semantic.symbol_table;
import semantic.ctfe;

import std.stdio;
import std.array;
import std.algorithm;
import std.conv : to;

/**
 * Mixin expansion error
 */
class MixinError : Exception {
    SourceLocation location;
    
    this(string msg, SourceLocation location, string file = __FILE__, size_t line = __LINE__) {
        this.location = location;
        super(msg ~ " at " ~ location.toString(), file, line);
    }
}

/**
 * Expands mixin declarations in a list of declarations.
 * 
 * This is a multi-pass process:
 * 1. First, collect all manifest constants and evaluate them via CTFE
 * 2. Then, expand each mixin by:
 *    a. Evaluating the mixin expression to get a string
 *    b. Parsing that string as D code
 *    c. Replacing the mixin with the parsed declarations
 * 
 * Returns a new declaration list with mixins expanded.
 */
class MixinExpander {
    private Declaration[] allDeclarations;
    private SymbolTable tempSymbolTable;
    private uint currentDepth = 0;
    private string backendName;
    
    /// Maximum mixin expansion depth to prevent infinite recursion
    enum MAX_EXPANSION_DEPTH = 100;
    
    this(string backendName = "wasm") {
        this.backendName = backendName;
        tempSymbolTable = new SymbolTable();
        tempSymbolTable.addBuiltinSymbols();
    }
    
    /**
     * Expand all mixins and static ifs in the declaration list.
     * Returns a new list with mixins/static ifs replaced by their expansions.
     */
    Declaration[] expandMixins(Declaration[] declarations) {
        allDeclarations = declarations;
        
        // First pass: collect manifest constants into temporary symbol table
        // and evaluate them (needed for static if conditions that reference them)
        setupCTFE();
        
        // Second pass: expand module-level mixins and static ifs
        Declaration[] result;
        foreach (decl; declarations) {
            if (auto mixinDecl = cast(MixinDecl)decl) {
                // Expand this mixin
                auto expanded = expandMixin(mixinDecl);
                result ~= expanded;
            } else if (auto staticIfDecl = cast(StaticIfDecl)decl) {
                // Expand this static if
                auto expanded = expandStaticIf(staticIfDecl);
                result ~= expanded;
            } else if (auto staticAssertDecl = cast(StaticAssertDecl)decl) {
                // Evaluate this static assert
                evaluateStaticAssert(staticAssertDecl);
                // Static asserts don't produce declarations, just validate
            } else {
                // Keep other declarations as-is
                result ~= decl;
            }
        }
        
        // Third pass: expand function-level mixins
        foreach (decl; result) {
            if (auto funcDecl = cast(FunctionDecl)decl) {
                if (funcDecl.body_) {
                    funcDecl.body_ = expandMixinsInStatement(funcDecl.body_);
                }
            }
        }
        
        return result;
    }
    
    /**
     * Expand mixins inside a statement (for function-level mixins).
     * Returns the statement with mixins expanded.
     */
    private Statement expandMixinsInStatement(Statement stmt) {
        if (auto compound = cast(CompoundStatement)stmt) {
            return expandMixinsInCompound(compound);
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            ifStmt.thenStatement = expandMixinsInStatement(ifStmt.thenStatement);
            if (ifStmt.elseStatement) {
                ifStmt.elseStatement = expandMixinsInStatement(ifStmt.elseStatement);
            }
            return ifStmt;
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            whileStmt.body_ = expandMixinsInStatement(whileStmt.body_);
            return whileStmt;
        } else if (auto forStmt = cast(ForStatement)stmt) {
            if (forStmt.init) {
                forStmt.init = expandMixinsInStatement(forStmt.init);
            }
            forStmt.body_ = expandMixinsInStatement(forStmt.body_);
            return forStmt;
        }
        // Other statements (return, expression, var decl) don't contain mixins
        return stmt;
    }
    
    /**
     * Expand mixins inside a compound statement.
     * MixinStatements are replaced with their expanded statements.
     */
    private CompoundStatement expandMixinsInCompound(CompoundStatement compound) {
        Statement[] newStatements;
        
        foreach (stmt; compound.statements) {
            if (auto mixinStmt = cast(MixinStatement)stmt) {
                // Expand the mixin
                auto expanded = expandMixinStatement(mixinStmt);
                newStatements ~= expanded;
            } else {
                // Recursively expand nested compound statements
                newStatements ~= expandMixinsInStatement(stmt);
            }
        }
        
        return new CompoundStatement(compound.location, newStatements);
    }
    
    /**
     * Expand a single mixin statement.
     * Returns the statements that the mixin expands to.
     */
    private Statement[] expandMixinStatement(MixinStatement mixinStmt) {
        writeln("Expanding mixin statement: ", mixinStmt.mixinExpr.toString());
        
        // Evaluate the mixin expression to get a string
        string mixinString = evaluateMixinExpression(mixinStmt.mixinExpr, mixinStmt.location);
        
        writeln("Mixin statement evaluates to: \"", mixinString, "\"");
        
        // Parse the string as D statements
        Statement[] parsed = parseMixinStatementString(mixinString, mixinStmt.location);
        
        writeln("Mixin statement parsed into ", parsed.length, " statements");
        
        // Store the expanded statements
        mixinStmt.expandedStatements = parsed;
        mixinStmt.isExpanded = true;
        
        return parsed;
    }
    
    /**
     * Parse a string as D statements (for function-level mixins).
     * Wraps the code in a dummy function to parse it.
     */
    private Statement[] parseMixinStatementString(string code, SourceLocation mixinLoc) {
        // Create a synthetic filename for error messages
        string filename = mixinLoc.filename ~ "(mixin)";
        
        // Wrap the code in a dummy function so we can parse it as statements
        string wrappedCode = "void __mixin_wrapper() { " ~ code ~ " }";
        
        try {
            auto bridge = new TreeSitterBridge(filename, wrappedCode);
            Declaration[] parsed = bridge.parseSourceFile();
            
            // Extract the statements from the wrapper function
            if (parsed.length > 0) {
                if (auto funcDecl = cast(FunctionDecl)parsed[0]) {
                    if (auto compound = cast(CompoundStatement)funcDecl.body_) {
                        return compound.statements;
                    }
                }
            }
            
            throw new MixinError(
                "Failed to parse mixin statements: empty result\nCode: \"" ~ code ~ "\"",
                mixinLoc
            );
        } catch (ParseError e) {
            throw new MixinError(
                "Failed to parse mixin code: " ~ e.msg ~ "\nCode: \"" ~ code ~ "\"",
                mixinLoc
            );
        } catch (Exception e) {
            throw new MixinError(
                "Unexpected error parsing mixin: " ~ e.msg,
                mixinLoc
            );
        }
    }
    
    /**
     * Set up symbol table and lazy CTFE resolver.
     * Actual evaluation happens on-demand when values are accessed.
     */
    private void setupCTFE() {
        // Collect all declarations into symbol table for CTFE
        // (structs, functions, manifest constants - everything CTFE might reference)
        auto collector = new SymbolCollector(tempSymbolTable);
        foreach (decl; allDeclarations) {
            collector.collectSymbol(decl);
        }
        
        // Create evaluator - this registers the lazy resolver with the symbol table
        // Actual evaluation happens when resolveManifestValue() is called
        new CTFEEvaluator(tempSymbolTable, allDeclarations, backendName);
    }
    
    /**
     * Expand a single mixin declaration.
     */
    private Declaration[] expandMixin(MixinDecl mixinDecl) {
        // Check depth limit to prevent infinite recursion
        if (currentDepth >= MAX_EXPANSION_DEPTH) {
            throw new MixinError(
                "Mixin expansion depth limit exceeded (max " ~ 
                to!string(MAX_EXPANSION_DEPTH) ~ "). Possible infinite recursion in mixin.",
                mixinDecl.location
            );
        }
        
        currentDepth++;
        scope(exit) currentDepth--;
        
        writeln("Expanding mixin (depth ", currentDepth, "): ", mixinDecl.mixinExpr.toString());
        
        // Evaluate the mixin expression to get a string
        string mixinString = evaluateMixinExpression(mixinDecl.mixinExpr, mixinDecl.location);
        
        writeln("Mixin evaluates to: \"", mixinString, "\"");
        
        // Parse the string as D code
        Declaration[] parsed = parseMixinString(mixinString, mixinDecl.location);
        
        // Convert simple variable declarations with constant initializers to manifest constants
        // This allows them to be used in CTFE and codegen
        Declaration[] converted;
        foreach (decl; parsed) {
            converted ~= maybeConvertToManifest(decl);
        }
        
        // Recursively expand any nested mixins in the result
        Declaration[] result;
        foreach (decl; converted) {
            if (auto nestedMixin = cast(MixinDecl)decl) {
                result ~= expandMixin(nestedMixin);
            } else if (auto nestedStaticIf = cast(StaticIfDecl)decl) {
                result ~= expandStaticIf(nestedStaticIf);
            } else {
                result ~= decl;
            }
        }
        
        writeln("Mixin parsed into ", result.length, " declarations");
        
        // Store the expanded declarations in the mixin node (for debugging)
        mixinDecl.expandedDeclarations = result;
        mixinDecl.isExpanded = true;
        
        return result;
    }
    
    /**
     * Expand a static if declaration.
     * Evaluates the condition at compile time and returns only the appropriate branch.
     */
    private Declaration[] expandStaticIf(StaticIfDecl staticIfDecl) {
        writeln("Expanding static if: ", staticIfDecl.condition.toString());
        
        // Extract identifiers from the condition (for incremental compilation tracking)
        string[] conditionDeps = extractIdentifiers(staticIfDecl.condition);
        
        // Evaluate the condition at compile time
        bool conditionResult = evaluateStaticIfCondition(staticIfDecl.condition, staticIfDecl.location);
        
        writeln("Static if condition evaluates to: ", conditionResult);
        
        // Select the appropriate branch
        Declaration[] selectedBranch;
        if (conditionResult) {
            selectedBranch = staticIfDecl.thenDeclarations;
            writeln("Taking then branch with ", selectedBranch.length, " declarations");
        } else {
            selectedBranch = staticIfDecl.elseDeclarations;
            writeln("Taking else branch with ", selectedBranch.length, " declarations");
        }
        
        // Recursively expand any nested static ifs or mixins in the selected branch
        Declaration[] result;
        foreach (decl; selectedBranch) {
            if (auto nestedStaticIf = cast(StaticIfDecl)decl) {
                result ~= expandStaticIf(nestedStaticIf);
            } else if (auto nestedMixin = cast(MixinDecl)decl) {
                result ~= expandMixin(nestedMixin);
            } else {
                result ~= decl;
            }
        }
        
        // Attach condition dependencies to resulting declarations
        // (for incremental compilation cache invalidation)
        foreach (decl; result) {
            decl.staticIfDependencies ~= conditionDeps;
        }
        
        // Store the expanded declarations in the node (for debugging)
        staticIfDecl.expandedDeclarations = result;
        staticIfDecl.isExpanded = true;
        
        return result;
    }
    
    /**
     * Extract all identifier names from an expression.
     * Used to track dependencies for incremental compilation.
     */
    private static string[] extractIdentifiers(Expression expr) {
        string[] ids;
        extractIdentifiersImpl(expr, ids);
        return ids;
    }
    
    private static void extractIdentifiersImpl(Expression expr, ref string[] ids) {
        if (expr is null) return;
        
        if (auto ident = cast(IdentifierExpression)expr) {
            ids ~= ident.name;
        } else if (auto binary = cast(BinaryExpression)expr) {
            extractIdentifiersImpl(binary.left, ids);
            extractIdentifiersImpl(binary.right, ids);
        } else if (auto unary = cast(UnaryExpression)expr) {
            extractIdentifiersImpl(unary.operand, ids);
        } else if (auto call = cast(CallExpression)expr) {
            extractIdentifiersImpl(call.function_, ids);
            foreach (arg; call.arguments) {
                extractIdentifiersImpl(arg, ids);
            }
        } else if (auto member = cast(MemberExpression)expr) {
            extractIdentifiersImpl(member.object, ids);
        } else if (auto index = cast(IndexExpression)expr) {
            extractIdentifiersImpl(index.array, ids);
            extractIdentifiersImpl(index.index, ids);
        }
        // LiteralExpression has no identifiers
    }
    
    /**
     * Evaluate a static assert at compile time.
     * Throws an error if the condition is false.
     */
    private void evaluateStaticAssert(StaticAssertDecl staticAssert) {
        if (staticAssert.isChecked) return;
        staticAssert.isChecked = true;
        
        bool conditionResult = evaluateStaticIfCondition(
            staticAssert.condition, 
            staticAssert.location
        );
        
        if (!conditionResult) {
            // Get the error message
            string errorMsg = "static assertion failed";
            if (staticAssert.message !is null) {
                if (auto literal = cast(LiteralExpression)staticAssert.message) {
                    if (literal.value.type == typeid(string)) {
                        errorMsg = literal.value.get!string();
                    }
                }
            }
            throw new MixinError(errorMsg, staticAssert.location);
        }
    }
    
    /**
     * Evaluate a static if condition at compile time.
     * Returns true or false.
     */
    private bool evaluateStaticIfCondition(Expression expr, SourceLocation loc) {
        // Handle boolean literals directly
        if (auto literal = cast(LiteralExpression)expr) {
            if (literal.value.type == typeid(bool)) {
                return literal.value.get!bool();
            }
            if (literal.value.type == typeid(long)) {
                // Integer literal: 0 is false, anything else is true
                return literal.value.get!long() != 0;
            }
            throw new MixinError("Static if condition must be a boolean expression", loc);
        }
        
        // Handle identifier (reference to manifest constant)
        if (auto ident = cast(IdentifierExpression)expr) {
            // Look up the manifest constant
            foreach (decl; allDeclarations) {
                if (auto manifest = cast(ManifestConstantDecl)decl) {
                    if (manifest.name == ident.name) {
                        // Lazy evaluation: resolve triggers CTFE if not yet evaluated
                        long value = tempSymbolTable.resolveManifestValue(manifest);
                        return value != 0;
                    }
                }
            }
            throw new MixinError("Undefined identifier '" ~ ident.name ~ "' in static if condition", loc);
        }
        
        // Handle comparison expressions (e.g., val > 3)
        if (auto binary = cast(BinaryExpression)expr) {
            long left = evaluateIntegerExpression(binary.left, loc);
            long right = evaluateIntegerExpression(binary.right, loc);
            
            final switch (binary.operator) {
                case BinaryExpression.Operator.Equal:
                    return left == right;
                case BinaryExpression.Operator.NotEqual:
                    return left != right;
                case BinaryExpression.Operator.Less:
                    return left < right;
                case BinaryExpression.Operator.LessEqual:
                    return left <= right;
                case BinaryExpression.Operator.Greater:
                    return left > right;
                case BinaryExpression.Operator.GreaterEqual:
                    return left >= right;
                case BinaryExpression.Operator.LogicalAnd:
                    return (left != 0) && (right != 0);
                case BinaryExpression.Operator.LogicalOr:
                    return (left != 0) || (right != 0);
                // Arithmetic operators - result is true if non-zero
                case BinaryExpression.Operator.Add:
                case BinaryExpression.Operator.Subtract:
                case BinaryExpression.Operator.Multiply:
                case BinaryExpression.Operator.Divide:
                case BinaryExpression.Operator.Modulo:
                case BinaryExpression.Operator.BitwiseAnd:
                case BinaryExpression.Operator.BitwiseOr:
                case BinaryExpression.Operator.BitwiseXor:
                case BinaryExpression.Operator.ShiftLeft:
                case BinaryExpression.Operator.ShiftRight:
                case BinaryExpression.Operator.UnsignedShiftRight:
                case BinaryExpression.Operator.Concat:
                    throw new MixinError("Non-comparison operator in static if condition", loc);
            }
        }
        
        throw new MixinError(
            "Unsupported expression type in static if condition: " ~ typeid(expr).toString(),
            loc
        );
    }
    
    /**
     * Evaluate an expression to an integer value for static if conditions.
     */
    private long evaluateIntegerExpression(Expression expr, SourceLocation loc) {
        // Handle integer literals
        if (auto literal = cast(LiteralExpression)expr) {
            if (literal.value.type == typeid(long)) {
                return literal.value.get!long();
            }
            if (literal.value.type == typeid(bool)) {
                return literal.value.get!bool() ? 1 : 0;
            }
            throw new MixinError("Expected integer in static if condition", loc);
        }
        
        // Handle identifier (reference to manifest constant)
        if (auto ident = cast(IdentifierExpression)expr) {
            // Look up the manifest constant
            foreach (decl; allDeclarations) {
                if (auto manifest = cast(ManifestConstantDecl)decl) {
                    if (manifest.name == ident.name) {
                        // Lazy evaluation: resolve triggers CTFE if not yet evaluated
                        return tempSymbolTable.resolveManifestValue(manifest);
                    }
                }
            }
            throw new MixinError("Undefined identifier '" ~ ident.name ~ "' in static if condition", loc);
        }
        
        throw new MixinError(
            "Unsupported expression type in static if integer evaluation: " ~ typeid(expr).toString(),
            loc
        );
    }
    
    /**
     * Convert a variable declaration with a constant initializer to a manifest constant.
     * This allows the variable to be used at compile time.
     */
    private Declaration maybeConvertToManifest(Declaration decl) {
        auto varDecl = cast(VariableDecl)decl;
        if (!varDecl) return decl;
        
        // Check if the initializer is a simple constant
        if (auto literal = cast(LiteralExpression)varDecl.initializer) {
            writeln("Converting variable '", varDecl.name, "' to manifest constant");
            auto manifest = new ManifestConstantDecl(varDecl.location, varDecl.name, literal);
            
            // Pre-evaluate the constant
            if (literal.value.type == typeid(long)) {
                manifest.ctfeValue = literal.value.get!long();
                manifest.ctfeComplete = true;
                manifest.inferredType = varDecl.type;
            } else if (literal.value.type == typeid(string)) {
                manifest.ctfeStringValue = literal.value.get!string();
                manifest.ctfeComplete = true;
                manifest.isStringType = true;
            }
            
            return manifest;
        }
        
        // For non-constant initializers, keep as variable declaration
        return decl;
    }
    
    /**
     * Evaluate a mixin expression to get its string value.
     */
    private string evaluateMixinExpression(Expression expr, SourceLocation loc) {
        // Handle identifier (reference to manifest constant)
        if (auto ident = cast(IdentifierExpression)expr) {
            // Look up the manifest constant
            foreach (decl; allDeclarations) {
                if (auto manifest = cast(ManifestConstantDecl)decl) {
                    if (manifest.name == ident.name) {
                        // Lazy evaluation via resolver
                        string value = tempSymbolTable.resolveManifestStringValue(manifest);
                        if (!manifest.isStringType) {
                            throw new MixinError(
                                "Mixin argument '" ~ ident.name ~ "' is not a string",
                                loc
                            );
                        }
                        return value;
                    }
                }
            }
            throw new MixinError("Undefined identifier '" ~ ident.name ~ "' in mixin", loc);
        }
        
        // Handle string literal directly
        if (auto literal = cast(LiteralExpression)expr) {
            if (literal.value.type == typeid(string)) {
                return literal.value.get!string();
            }
            throw new MixinError("Mixin argument must be a string", loc);
        }
        
        // Handle binary expression (string concatenation) - should already be evaluated
        // via manifest constant
        throw new MixinError(
            "Unsupported mixin expression type: " ~ typeid(expr).toString(),
            loc
        );
    }
    
    /**
     * Parse a string as D code and return the declarations.
     */
    private Declaration[] parseMixinString(string code, SourceLocation mixinLoc) {
        // Create a synthetic filename for error messages
        string filename = mixinLoc.filename ~ "(mixin)";
        
        try {
            auto bridge = new TreeSitterBridge(filename, code);
            Declaration[] parsed = bridge.parseSourceFile();
            return parsed;
        } catch (ParseError e) {
            throw new MixinError(
                "Failed to parse mixin code: " ~ e.msg ~ "\nCode: \"" ~ code ~ "\"",
                mixinLoc
            );
        } catch (Exception e) {
            throw new MixinError(
                "Unexpected error parsing mixin: " ~ e.msg,
                mixinLoc
            );
        }
    }
}
