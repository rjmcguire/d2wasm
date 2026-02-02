/**
 * Mixin Expansion for D-to-WASM Compiler
 * 
 * This module handles the expansion of mixin declarations.
 * It evaluates mixin expressions at compile time and parses
 * the resulting strings as D code.
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
        
        // Second pass: expand mixins
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
        
        return result;
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
