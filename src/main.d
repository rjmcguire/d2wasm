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
    
    // Parallel compilation options
    string[] inputFiles;      // Multiple input files (for parallel mode)
    string outputDir;         // Output directory for parallel mode
    int maxParallel = 0;      // Max parallel compilations (0 = auto)
    
    // Watch mode options
    bool watch = false;       // Watch files and recompile on change
    
    // Debug options
    bool stackTrace = true;   // Emit call stack tracking for CTFE errors (default: on)
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
            "outdir", "Output directory for parallel mode", &options.outputDir,
            "backend|b", "Code generation backend: wasm, native (default: wasm)", &options.backend,
            "run|r", "Compile and run immediately (like rdmd)", &options.run,
            "func|f", "Function to run with --run (default: main)", &options.runFunc,
            "dry-run|n", "Parse and validate only, don't generate code", &options.dryRun,
            "print-ast", "Print the AST after parsing", &options.printAst,
            "validate-only", "Only run feature validation", &options.onlyValidate,
            // Incremental compilation
            "cache", "Cache directory for incremental compilation", &options.cacheDir,
            "staging", "Staging file output path", &options.stagingFile,
            "json", "Output JSON summary (for incremental mode)", &options.jsonOutput,
            // Parallel compilation
            "jobs|j", "Max parallel compilations (0 = auto)", &options.maxParallel,
            // Watch mode
            "watch|w", "Watch files and recompile on change", &options.watch,
            // Debug options
            "stack-trace", "Emit call stack tracking for CTFE errors (default: on)", &options.stackTrace
        );
        
        log(3, "main() started");
        
        if (helpInformation.helpWanted) {
            defaultGetoptPrinter("D-to-WASM Compiler\n" ~
                "Compiles a subset of D language to WebAssembly\n" ~
                "\nUsage: d2wasm [options] input.d [input2.d ...]\n" ~
                "\nVerbosity: -v (progress), -vv (detail), -vvv (debug)\n",
                helpInformation.options);
            return 0;
        }
        
        // Collect all positional arguments as input files
        if (args.length > 1) {
            options.inputFiles = args[1..$].dup;
        }
        
        // If single -i option was used, add to inputFiles
        if (options.inputFile.length > 0 && !options.inputFiles.canFind(options.inputFile)) {
            options.inputFiles = [options.inputFile] ~ options.inputFiles;
        }
        
        // Handle multiple input files (parallel mode)
        if (options.inputFiles.length > 1) {
            return runParallel(options);
        }
        
        // Single file mode
        if (options.inputFiles.length == 1) {
            options.inputFile = options.inputFiles[0];
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
        
        // Watch mode
        if (options.watch) {
            return runWatch(options);
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
        
        // Extract module declaration if present
        foreach (decl; ast) {
            if (auto moduleDecl = cast(ModuleDecl)decl) {
                symbolTable.setModulePath(moduleDecl.modulePath);
                log(2, "Module: ", symbolTable.moduleFullyQualifiedName());
                break;  // Only one module declaration per file
            }
        }
        
        auto symbolCollector = new SymbolCollector(symbolTable);
        symbolCollector.collectSymbols(ast);
        
        log(2, "Symbol table built with ", symbolTable.getGlobalScope().getAllSymbols().length, " global symbols");
        
        // 5. CTFE setup (lazy evaluation - must be before type checking)
        // Type checking may need to resolve manifest constant types
        log(2, "Setting up CTFE resolver...");
        
        import semantic.ctfe;
        // Create evaluator - registers lazy resolver with symbol table
        // Actual evaluation happens when manifest constant values are accessed
        auto ctfeEvaluator = new CTFEEvaluator(symbolTable, ast, options.backend, options.stackTrace);
        
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
            
            auto emitter = new BinaryEmitter(symbolTable, options.stackTrace);
            
            // Load cache if enabled
            import cache.compiler_cache : CompilerCache;
            import cache.entry : CacheEntry;
            CompilerCache cache;
            if (options.cacheDir.length > 0) {
                string moduleName = baseName(stripExtension(options.inputFile));
                cache = new CompilerCache(options.cacheDir, moduleName);
                
                // Set source text for hash computation
                emitter.setSourceText(sourceCode);
                
                // Load cached entries
                auto cachedEntries = cache.getEntries();
                if (cachedEntries.length > 0) {
                    emitter.setCodeCache(cachedEntries);
                    log(2, "Loaded ", cachedEntries.length, " cached function(s)");
                }
            }
            
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
            
            // 9. Cache storage (if enabled)
            if (cache !is null) {
                import std.json;
                
                // Store emitted code back to cache
                auto emittedCode = emitter.getEmittedCode();
                cache.storeEntries(emittedCode);
                cache.flush();
                
                auto emitterStats = emitter.getCacheStats();
                log(2, "Cache: ", emitterStats.cacheHits, " hits, ", 
                    emitterStats.cacheMisses, " misses");
                
                // JSON output mode
                if (options.jsonOutput) {
                    string moduleName = baseName(stripExtension(options.inputFile));
                    JSONValue json;
                    json["module"] = moduleName;
                    json["input"] = options.inputFile;
                    json["output"] = options.outputFile;
                    json["success"] = true;
                    json["wasmSize"] = wasm.length;
                    json["cacheHits"] = cast(int)emitterStats.cacheHits;
                    json["cacheMisses"] = cast(int)emitterStats.cacheMisses;
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
 * Run watch mode - recompile on file changes.
 */
int runWatch(CompilerOptions options) {
    import watcher.watcher : createDebouncedWatcher, DebouncedWatcher;
    import watcher.fsevents_watcher : FSEventsWatcher;
    import cache.entry : SourceHash, CacheEntry;
    import std.datetime : Clock;
    import std.path : dirName;
    import core.thread : Thread;
    import core.time : dur;
    
    writeln("[", formatTime(), "] Watching: ", options.inputFile);
    writeln("[", formatTime(), "] Output: ", options.outputFile);
    if (options.cacheDir.length > 0) {
        writeln("[", formatTime(), "] Cache: ", options.cacheDir);
    }
    writeln();
    stdout.flush();
    
    // Track last error hash to avoid repeating same error
    ubyte[32] lastErrorHash;
    bool hadError = false;
    
    // Initial compile
    auto result = compileFileForWatch(options, lastErrorHash, hadError);
    
    // Create watcher
    version(OSX) {
        auto innerWatcher = new FSEventsWatcher();
        
        auto watcher = new DebouncedWatcher(innerWatcher, (paths) {
            import std.algorithm : any;
            import std.path : extension;
            
            // Filter to only .d files
            bool hasD = paths.any!(p => p.extension == ".d");
            if (!hasD) return;
            
            writeln();
            writeln("[", formatTime(), "] Changed: ", options.inputFile);
            stdout.flush();
            compileFileForWatch(options, lastErrorHash, hadError);
            stdout.flush();
        }, 200);
        
        // Watch the directory containing the file
        innerWatcher.setCallback((paths) {
            watcher.onRawChange(paths);
        });
        
        string watchDir = dirName(options.inputFile);
        if (watchDir.length == 0) watchDir = ".";
        innerWatcher.addPath(watchDir);
        
        writeln("[", formatTime(), "] Press Ctrl+C to stop\n");
        stdout.flush();
        
        // This blocks until stopped
        watcher.start();
    } else {
        writeln("Watch mode not supported on this platform");
        return 1;
    }
    
    return 0;
}

/// Format current time for log output
private string formatTime() {
    import std.datetime : Clock;
    auto now = Clock.currTime();
    return format("%02d:%02d:%02d", now.hour, now.minute, now.second);
}

/// Compile file for watch mode, handling errors gracefully
private int compileFileForWatch(ref CompilerOptions options, 
                                ref ubyte[32] lastErrorHash, ref bool hadError) {
    import std.file : read, exists;
    
    // Compute source hash to detect unchanged files
    if (!exists(options.inputFile)) {
        writeln("[", formatTime(), "] File not found: ", options.inputFile);
        return 1;
    }
    
    auto sourceHash = computeErrorHash(cast(string)read(options.inputFile));
    
    // Skip recompile if source unchanged and we had error
    if (hadError && sourceHash == lastErrorHash) {
        writeln("[", formatTime(), "] (unchanged after error, skipped)");
        stdout.flush();
        return 1;
    }
    
    // Compile
    auto result = compileFile(options);
    
    if (result == 0) {
        // Success - clear error state
        hadError = false;
        lastErrorHash = typeof(lastErrorHash).init;
    } else {
        // Error - record source hash
        hadError = true;
        lastErrorHash = sourceHash;
    }
    
    return result;
}

/// Compute hash of error message
private ubyte[32] computeErrorHash(string msg) {
    import std.digest.murmurhash : MurmurHash3;
    
    ubyte[32] result;
    auto hash1 = MurmurHash3!128(0);
    auto hash2 = MurmurHash3!128(0x9E3779B9);
    
    hash1.put(cast(const(ubyte)[])msg);
    hash2.put(cast(const(ubyte)[])msg);
    
    auto h1 = hash1.finish();
    auto h2 = hash2.finish();
    
    result[0..16] = h1[];
    result[16..32] = h2[];
    return result;
}

/**
 * Run parallel compilation of multiple files.
 */
int runParallel(CompilerOptions options) {
    import codegen.orchestrator : Orchestrator, OrchestratorResult;
    import std.json;
    import diagnostic.log : log;
    
    // Get the path to ourselves
    import core.runtime : Runtime;
    string compilerPath = Runtime.args[0];
    
    // Use output directory or current directory
    string outDir = options.outputDir.length > 0 ? options.outputDir : ".";
    
    log(1, "Parallel compilation of ", options.inputFiles.length, " files...");
    
    auto orchestrator = new Orchestrator(
        compilerPath,
        options.cacheDir,
        outDir,
        options.maxParallel
    );
    orchestrator.setVerbosity(options.verbosity);
    
    auto result = orchestrator.compile(options.inputFiles);
    
    // Output results
    if (options.jsonOutput) {
        JSONValue json;
        json["totalFiles"] = result.totalFiles;
        json["success"] = result.successCount;
        json["failed"] = result.failCount;
        json["cacheHits"] = result.totalCacheHits;
        json["cacheMisses"] = result.totalCacheMisses;
        
        JSONValue[] fileResults;
        foreach (r; result.results) {
            JSONValue fr;
            fr["input"] = r.inputFile;
            fr["output"] = r.outputFile;
            fr["success"] = r.success;
            if (!r.success) {
                fr["error"] = r.error;
            } else {
                fr["wasmSize"] = r.wasmSize;
                fr["cacheHits"] = r.cacheHits;
                fr["cacheMisses"] = r.cacheMisses;
            }
            fileResults ~= fr;
        }
        json["files"] = fileResults;
        
        writeln(json.toPrettyString());
    } else {
        // Normal output
        foreach (r; result.results) {
            if (r.success) {
                log(1, "Compiled ", r.inputFile, " -> ", r.outputFile);
            } else {
                writeln("Failed: ", r.inputFile);
                writeln("  ", r.error);
            }
        }
        
        writeln();
        writeln("Results: ", result.successCount, " succeeded, ", 
                result.failCount, " failed");
        
        if (options.cacheDir.length > 0) {
            writeln("Cache: ", result.totalCacheHits, " hits, ",
                    result.totalCacheMisses, " misses");
        }
    }
    
    return result.allSucceeded() ? 0 : 1;
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