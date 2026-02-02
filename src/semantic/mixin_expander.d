/**
 * Mixin Expansion for D-to-WASM Compiler
 * 
 * This module handles the expansion of mixin declarations.
 * It evaluates mixin expressions at compile time and parses
 * the resulting strings as D code.
 * 
 * Supports both:
 * - Module-level mixins (expand to declarations)
 * - Function-level mixins (expand to statements)
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
    
    this() {
        tempSymbolTable = new SymbolTable();
        tempSymbolTable.addBuiltinSymbols();
    }
    
    /**
     * Expand all mixins in the declaration list.
     * Returns a new list with mixins replaced by their expansions.
     */
    Declaration[] expandMixins(Declaration[] declarations) {
        allDeclarations = declarations;
        
        // First pass: collect manifest constants into temporary symbol table
        // and evaluate them
        collectAndEvaluateManifests();
        
        // Second pass: expand module-level mixins
        Declaration[] result;
        foreach (decl; declarations) {
            if (auto mixinDecl = cast(MixinDecl)decl) {
                // Expand this mixin
                auto expanded = expandMixin(mixinDecl);
                result ~= expanded;
            } else {
                // Keep non-mixin declarations as-is
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
     * Collect manifest constants and evaluate them via CTFE.
     */
    private void collectAndEvaluateManifests() {
        // Collect manifest constants into symbol table
        auto collector = new SymbolCollector(tempSymbolTable);
        foreach (decl; allDeclarations) {
            if (cast(ManifestConstantDecl)decl) {
                collector.collectSymbol(decl);
            }
        }
        
        // Evaluate them via CTFE
        auto ctfe = new CTFEEvaluator(tempSymbolTable, allDeclarations);
        ctfe.evaluateManifestConstants();
    }
    
    /**
     * Expand a single mixin declaration.
     */
    private Declaration[] expandMixin(MixinDecl mixinDecl) {
        writeln("Expanding mixin: ", mixinDecl.mixinExpr.toString());
        
        // Evaluate the mixin expression to get a string
        string mixinString = evaluateMixinExpression(mixinDecl.mixinExpr, mixinDecl.location);
        
        writeln("Mixin evaluates to: \"", mixinString, "\"");
        
        // Parse the string as D code
        Declaration[] parsed = parseMixinString(mixinString, mixinDecl.location);
        
        // Convert simple variable declarations with constant initializers to manifest constants
        // This allows them to be used in CTFE and codegen
        Declaration[] result;
        foreach (decl; parsed) {
            result ~= maybeConvertToManifest(decl);
        }
        
        writeln("Mixin parsed into ", result.length, " declarations");
        
        // Store the expanded declarations in the mixin node (for debugging)
        mixinDecl.expandedDeclarations = result;
        mixinDecl.isExpanded = true;
        
        return result;
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
                        if (!manifest.ctfeComplete) {
                            throw new MixinError(
                                "Manifest constant '" ~ ident.name ~ "' not yet evaluated",
                                loc
                            );
                        }
                        if (!manifest.isStringType) {
                            throw new MixinError(
                                "Mixin argument '" ~ ident.name ~ "' is not a string",
                                loc
                            );
                        }
                        return manifest.ctfeStringValue;
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
