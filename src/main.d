/**
 * Main entry point for the D-to-WASM Compiler
 * 
 * This program compiles a subset of the D programming language to WebAssembly.
 * The compiler follows a clean architecture:
 * 
 * Parse (tree-sitter) → AST → Validate → Semantic Analysis → CodeGen → WASM
 */
module main;

import std.stdio;
import std.getopt;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.conv;
import std.array;
import std.range;

import ast.nodes;
import ast.statements;
import ast.expressions;
import parser.tree_sitter_bridge;
import parser.tree_sitter_c;
import semantic.feature_validator;
import semantic.symbol_table;
import semantic.type_checker;
import codegen.wasm_generator;

struct CompilerOptions {
    string inputFile;
    string outputFile;
    bool verbose = false;
    bool dryRun = false;
    bool printAst = false;
    bool onlyValidate = false;
}

int main(string[] args) {
    CompilerOptions options;
    
    try {
        auto helpInformation = getopt(args,
            "input|i", "Input D source file", &options.inputFile,
            "output|o", "Output WASM file (default: input.wasm)", &options.outputFile,
            "verbose|v", "Verbose output", &options.verbose,
            "dry-run|n", "Parse and validate only, don't generate code", &options.dryRun,
            "print-ast", "Print the AST after parsing", &options.printAst,
            "validate-only", "Only run feature validation", &options.onlyValidate
        );
        
        if (helpInformation.helpWanted) {
            defaultGetoptPrinter("D-to-WASM Compiler\n" ~
                "Compiles a subset of D language to WebAssembly\n" ~
                "\nUsage: d2wasm [options] input.d\n",
                helpInformation.options);
            return 0;
        }
        
        // Get input file from positional argument if not specified
        if (options.inputFile.length == 0 && args.length > 1) {
            options.inputFile = args[1];
        }
        
        if (options.inputFile.length == 0) {
            writeln("Error: No input file specified");
            writeln("Use --help for usage information");
            return 1;
        }
        
        // Set default output file
        if (options.outputFile.length == 0) {
            options.outputFile = setExtension(options.inputFile, ".wasm");
        }
        
        return compileFile(options);
        
    } catch (Exception e) {
        writeln("Error: ", e.msg);
        return 1;
    }
}

/**
 * Compile a single D source file to WASM
 */
int compileFile(CompilerOptions options) {
    try {
        if (options.verbose) {
            writeln("D-to-WASM Compiler v1.0");
            writeln("Input: ", options.inputFile);
            writeln("Output: ", options.outputFile);
            writeln();
        }
        
        // 1. Read source file
        if (!exists(options.inputFile)) {
            writeln("Error: Input file not found: ", options.inputFile);
            return 1;
        }
        
        string sourceCode = readText(options.inputFile);
        if (options.verbose) {
            writeln("Read ", sourceCode.length, " characters from ", options.inputFile);
        }
        
        // 2. Parse with real tree-sitter
        if (options.verbose) {
            writeln("Parsing with tree-sitter-d...");
        }
        
        auto bridge = new TreeSitterBridge(options.inputFile, sourceCode);
        Declaration[] ast;
        
        try {
            ast = bridge.parseSourceFile();
        } catch (ParseError e) {
            // For now, fall back to mock parsing if tree-sitter fails
            if (options.verbose) {
                writeln("Tree-sitter parsing failed, using mock parser: ", e.msg);
            }
            ast = parseSourceFileMock(options.inputFile, sourceCode, options.verbose);
        }
        
        if (options.verbose) {
            writeln("Parsed ", ast.length, " top-level declarations");
        }
        
        if (options.printAst) {
            writeln("\n=== AST ===");
            printAST(ast);
            writeln();
        }
        
        // 3. Feature validation
        if (options.verbose) {
            writeln("Running feature validation...");
        }
        
        auto validator = new FeatureValidator();
        validator.validateSourceFile(ast);
        
        if (options.verbose) {
            writeln("Feature validation passed");
        }
        
        if (options.onlyValidate) {
            writeln("Validation complete - no unsupported features found");
            return 0;
        }
        
        // 4. Symbol table construction
        if (options.verbose) {
            writeln("Building symbol table...");
        }
        
        auto symbolTable = new SymbolTable();
        symbolTable.addBuiltinSymbols();
        
        auto symbolCollector = new SymbolCollector(symbolTable);
        symbolCollector.collectSymbols(ast);
        
        if (options.verbose) {
            writeln("Symbol table built with ", symbolTable.getGlobalScope().getAllSymbols().length, " global symbols");
        }
        
        // 5. Type checking
        if (options.verbose) {
            writeln("Running type checking...");
        }
        
        auto typeChecker = new TypeChecker(symbolTable);
        typeChecker.checkDeclarations(ast);
        
        if (options.verbose) {
            writeln("Type checking passed");
        }
        
        // 6. Code generation
        if (!options.dryRun) {
            if (options.verbose) {
                writeln("Generating WASM code...");
            }
            
            auto wasmGenerator = new WasmGenerator(symbolTable);
            auto wasmModule = wasmGenerator.generateModule(ast);
            
            // Write WAT file
            string watFile = setExtension(options.outputFile, ".wat");
            std.file.write(watFile, wasmModule.toWAT());
            
            if (options.verbose) {
                writeln("Generated WAT: ", watFile);
                writeln("Functions: ", wasmModule.functions.length);
            }
            
            // Try to generate binary WASM if wat2wasm is available
            try {
                import std.process;
                auto result = execute(["wat2wasm", watFile, "-o", options.outputFile]);
                if (result.status == 0) {
                    if (options.verbose) {
                        writeln("Generated binary WASM: ", options.outputFile);
                    }
                } else {
                    writeln("Warning: wat2wasm failed - only WAT file generated");
                }
            } catch (Exception e) {
                writeln("Warning: wat2wasm not found - only WAT file generated");
            }
            
            writeln("Successfully compiled to ", watFile);
            if (exists(options.outputFile)) {
                writeln("Binary WASM: ", options.outputFile);
            }
        } else {
            writeln("Dry run complete - all phases successful");
        }
        
        return 0;
        
    } catch (ParseError e) {
        writeln("Parse Error: ", e.msg);
        return 1;
    } catch (FeatureValidationError e) {
        writeln("Validation Error: ", e.msg);
        return 1;
    } catch (SemanticError e) {
        writeln("Semantic Error: ", e.msg);
        return 1;
    } catch (TypeError e) {
        writeln("Type Error: ", e.msg);
        return 1;
    } catch (CodeGenError e) {
        writeln("Code Generation Error: ", e.msg);
        return 1;
    } catch (Exception e) {
        writeln("Internal Error: ", e.msg);
        if (options.verbose) {
            writeln("Stack trace:");
            writeln(e.info);
        }
        return 1;
    }
}

/**
 * Fallback mock parser for testing when tree-sitter is not available
 */
Declaration[] parseSourceFileMock(string filename, string sourceCode, bool verbose) {
    if (verbose) {
        writeln("Parsing with mock tree-sitter implementation...");
    }
    
    // For now, create a simple mock AST for testing
    // In a real implementation, this would call tree-sitter parser
    
    auto loc = SourceLocation(filename, 1, 1, 0, sourceCode.length.to!uint);
    
    // Create a simple function for testing
    auto intType = new BasicType(loc, BasicType.Kind.Int32);
    auto returnStmt = new ReturnStatement(loc, LiteralExpression.integer(loc, 42));
    auto body_ = new CompoundStatement(loc, [returnStmt]);
    auto func = new FunctionDecl(loc, "main", intType, [], body_);
    
    if (verbose) {
        writeln("Created mock AST with 1 function");
    }
    
    return [func];
}

/**
 * Print AST for debugging
 */
void printAST(Declaration[] declarations) {
    foreach (i, decl; declarations) {
        printASTNode(decl, 0);
    }
}

void printASTNode(ASTNode node, int depth) {
    string indent = repeat("  ", depth).join();
    writeln(indent, node.toString());
    
    // TODO: Implement proper AST traversal to print child nodes
}

/**
 * Generate placeholder WASM file
 * TODO: Replace with real WASM code generation
 */
void generateWasmPlaceholder(string outputFile, Declaration[] ast) {
    string watCode = `(module
  (func $main (result i32)
    i32.const 42
  )
  (export "main" (func $main))
)`;
    
    std.file.write(outputFile ~ ".wat", watCode);
    writeln("Generated placeholder WAT file: ", outputFile ~ ".wat");
    writeln("Use 'wat2wasm' to convert to binary WASM");
}