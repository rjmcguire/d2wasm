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
import parser.tree_sitter_bridge : TreeSitterBridge, ParseError;
import parser.tree_sitter_c;
import semantic.feature_validator;
import semantic.symbol_table;
import semantic.type_checker;
import codegen.emitter;
import codegen.backend;
import diagnostic.error_format : printError;

struct CompilerOptions {
    string inputFile;
    string outputFile;
    string backend = "wasm";  // Backend: "wasm" or "native"
    int verbosity = 0;        // 0=quiet, 1=-v, 2=-vv, 3=-vvv
    bool dryRun = false;
    bool printAst = false;
    bool onlyValidate = false;
    bool run = false;         // Compile and run immediately
    string runFunc = "main";  // Function to run (default: main)
    
    // Incremental compilation options
    string cacheDir;          // Cache directory (enables incremental mode)
    string stagingFile;       // Output staging file path
    bool jsonOutput = false;  // Output JSON summary instead of normal output
}

int main(string[] args) {
    import diagnostic.log : setVerbosity, log;
    
    CompilerOptions options;
    
    // Pre-parse verbosity flags before getopt (handles -v, -vv, -vvv)
    string[] filteredArgs = [args[0]];  // Keep program name
    foreach (arg; args[1..$]) {
        if (arg == "-v") {
            options.verbosity++;
        } else if (arg == "-vv") {
            options.verbosity = 2;
        } else if (arg == "-vvv") {
            options.verbosity = 3;
        } else if (arg.startsWith("--verbose=")) {
            auto val = arg["--verbose=".length..$];
            if (val.all!(c => c == 'v')) {
                options.verbosity = cast(int)val.length;
            } else {
                options.verbosity = to!int(val);
            }
        } else {
            filteredArgs ~= arg;
        }
    }
    args = filteredArgs;
    setVerbosity(options.verbosity);
    
    try {
        auto helpInformation = getopt(args,
            "input|i", "Input D source file", &options.inputFile,
            "output|o", "Output WASM file (default: input.wasm)", &options.outputFile,
            "backend|b", "Code generation backend: wasm, native (default: wasm)", &options.backend,
            "run|r", "Compile and run immediately (like rdmd)", &options.run,
            "func|f", "Function to run with --run (default: main)", &options.runFunc,
            "dry-run|n", "Parse and validate only, don't generate code", &options.dryRun,
            "print-ast", "Print the AST after parsing", &options.printAst,
            "validate-only", "Only run feature validation", &options.onlyValidate,
            // Incremental compilation
            "cache", "Cache directory for incremental compilation", &options.cacheDir,
            "staging", "Staging file output path", &options.stagingFile,
            "json", "Output JSON summary (for incremental mode)", &options.jsonOutput
        );
        
        log(3, "main() started");
        
        if (helpInformation.helpWanted) {
            defaultGetoptPrinter("D-to-WASM Compiler\n" ~
                "Compiles a subset of D language to WebAssembly\n" ~
                "\nUsage: d2wasm [options] input.d\n" ~
                "\nVerbosity: -v (progress), -vv (detail), -vvv (debug)\n",
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
    import diagnostic.log : log;
    
    try {
        log(1, "D-to-WASM Compiler v1.0");
        log(1, "Input: ", options.inputFile);
        log(1, "Output: ", options.outputFile);
        log(1, "Backend: ", options.backend);
        
        // 1. Read source file
        if (!exists(options.inputFile)) {
            writeln("Error: Input file not found: ", options.inputFile);
            return 1;
        }
        
        string sourceCode = readText(options.inputFile);
        log(2, "Read ", sourceCode.length, " characters from ", options.inputFile);
        
        // 2. Parse with real tree-sitter
        log(1, "Parsing with tree-sitter-d...");
        log(3, "About to create TreeSitterBridge...");
        auto bridge = new TreeSitterBridge(options.inputFile, sourceCode);
        log(3, "TreeSitterBridge created successfully.");
        Declaration[] ast;
        
        try {
            ast = bridge.parseSourceFile();
            log(2, "Tree-sitter parsing successful!");
        } catch (ParseError e) {
            printError(e);
            return 1;
        } catch (Exception e) {
            writeln("Unexpected error during parsing: ", e.msg);
            log(1, "Stack trace: ", e.info);
            return 1;
        }
        
        log(2, "Parsed ", ast.length, " top-level declarations");
        
        if (options.printAst) {
            writeln("\n=== AST (before mixin expansion) ===");
            printAST(ast);
            writeln();
        }
        
        // 2b. Mixin expansion - must happen before symbol collection
        log(1, "Expanding mixins...");
        
        import semantic.mixin_expander;
        auto mixinExpander = new MixinExpander(options.backend);
        try {
            ast = mixinExpander.expandMixins(ast);
        } catch (MixinError e) {
            printError(e);
            return 1;
        }
        
        log(2, "Mixin expansion complete. ", ast.length, " declarations after expansion");
        
        if (options.printAst) {
            writeln("\n=== AST (after mixin expansion) ===");
            printAST(ast);
            writeln();
        }
        
        // 3. Feature validation
        log(1, "Running feature validation...");
        
        auto validator = new FeatureValidator();
        validator.validateSourceFile(ast);
        
        log(2, "Feature validation passed");
        
        if (options.onlyValidate) {
            writeln("Validation complete - no unsupported features found");
            return 0;
        }
        
        // 4. Symbol table construction
        log(1, "Building symbol table...");
        
        auto symbolTable = new SymbolTable();
        symbolTable.addBuiltinSymbols();
        
        auto symbolCollector = new SymbolCollector(symbolTable);
        symbolCollector.collectSymbols(ast);
        
        log(2, "Symbol table built with ", symbolTable.getGlobalScope().getAllSymbols().length, " global symbols");
        
        // 5. CTFE setup (lazy evaluation - must be before type checking)
        // Type checking may need to resolve manifest constant types
        log(2, "Setting up CTFE resolver...");
        
        import semantic.ctfe;
        // Create evaluator - registers lazy resolver with symbol table
        // Actual evaluation happens when manifest constant values are accessed
        auto ctfeEvaluator = new CTFEEvaluator(symbolTable, ast, options.backend);
        
        log(2, "CTFE resolver ready");
        
        // 6. Type checking
        log(1, "Running type checking...");
        
        auto typeChecker = new TypeChecker(symbolTable);
        typeChecker.checkDeclarations(ast);
        
        log(1, "Type checking passed");
        
        // 6b. Evaluate remaining manifest constants (for side-effect-only CTFE like enum _ = ctfeMain())
        // Lazy evaluation only triggers when values are accessed; this ensures all CTFE runs
        log(2, "Evaluating manifest constants...");
        ctfeEvaluator.evaluateManifestConstants();
        
        // 7. Code generation (binary WASM emission)
        if (!options.dryRun) {
            log(1, "Generating binary WASM...");
            
            auto emitter = new BinaryEmitter(symbolTable);
            ubyte[] wasm = emitter.emit(ast);
            
            if (wasm is null) {
                writeln("Code Generation Error: ", emitter.error());
                return 1;
            }
            
            std.file.write(options.outputFile, wasm);
            
            log(1, "Generated ", wasm.length, " bytes of binary WASM");
            
            // 8. Run if requested (like rdmd)
            //
            // IMPORTANT: We deliberately read from the file we just wrote, NOT from
            // the in-memory wasm bytes. This is intentional:
            //   1. Proves the written file is valid and complete
            //   2. Ensures what we run matches what's on disk exactly
            //   3. Catches any file I/O issues (permissions, disk full, etc.)
            //
            // Do NOT "optimize" this to use the in-memory bytes directly!
            if (options.run) {
                log(1, "Running ", options.runFunc, " from ", options.outputFile, "...");
                
                import semantic.ctfe_runtime : CTFERuntime;
                auto wasmFromFile = cast(ubyte[])std.file.read(options.outputFile);
                
                auto runner = new CTFERuntime();
                runner.loadModule(wasmFromFile);
                
                int result = runner.callI32(options.runFunc).asInt();
                log(1, "Exit code: ", result);
                
                // Print CTFE stats at verbosity 2+
                if (options.verbosity >= 2) {
                    ctfeEvaluator.printStats();
                }
                
                return result;
            }
            
            // 9. Cache integration (if enabled)
            if (options.cacheDir.length > 0) {
                import cache.compiler_cache : CompilerCache;
                import std.json;
                
                string moduleName = baseName(stripExtension(options.inputFile));
                auto cache = new CompilerCache(options.cacheDir, moduleName);
                
                // Record all compiled functions
                foreach (decl; ast) {
                    if (auto func = cast(FunctionDecl)decl) {
                        cache.recordFunction(func, ast, sourceCode, wasm);
                    }
                }
                
                // Write to staging file
                if (options.stagingFile.length > 0) {
                    import cache.staging : writeStagingFile;
                    import std.path : dirName;
                    // Use custom staging path
                    auto stagingDir = dirName(options.stagingFile);
                    cache.flush();  // Writes to default staging dir
                }
                cache.flush();
                
                // JSON output mode
                if (options.jsonOutput) {
                    auto stats = cache.getStats();
                    JSONValue json;
                    json["module"] = moduleName;
                    json["input"] = options.inputFile;
                    json["output"] = options.outputFile;
                    json["success"] = true;
                    json["wasmSize"] = wasm.length;
                    json["cacheHits"] = stats.cacheHits;
                    json["cacheMisses"] = stats.cacheMisses;
                    json["compiled"] = JSONValue(stats.recompiledMembers);
                    json["cached"] = JSONValue(stats.cachedMembers);
                    writeln(json.toPrettyString());
                    return 0;
                }
            }
            
            writeln("Successfully compiled to ", options.outputFile);
        } else {
            writeln("Dry run complete - frontend phases successful");
        }
        
        // Print CTFE stats at verbosity 2+
        if (options.verbosity >= 2) {
            ctfeEvaluator.printStats();
        }
        
        return 0;
        
    } catch (ParseError e) {
        printError(e);
        return 1;
    } catch (FeatureValidationError e) {
        printError(e);
        return 1;
    } catch (SemanticError e) {
        printError(e);
        return 1;
    } catch (TypeError e) {
        printError(e);
        return 1;
    } catch (Exception e) {
        writeln("Internal Error: ", e.msg);
        log(1, "Stack trace:");
        log(1, e.info);
        return 1;
    }
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