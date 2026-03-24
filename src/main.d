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
import parser.tree_sitter_bridge : ParseError;
import parser.tree_sitter_c;
import parser.d_parser : DParser;
import parser.source_parser : ParseFn;
import semantic.feature_validator;
import semantic.symbol_table;
import semantic.type_checker;
import codegen.emitter;
import codegen.backend;
import incremental.dep_graph : DeclDependencyGraph;
import incremental.graph_builder : GraphBuilder;
import diagnostic.error_format : printError;
import semantic.ctfe : CTFEError;
import semantic.arena_taint : ArenaSafetyError;
import semantic.import_resolver : ImportError;

struct CompilerOptions {
    string inputFile;
    string outputFile;
    string target = "wasm";   // Target: "wasm" (default), "arm64-macos"
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

    // Server mode options
    bool serverMode = false;      // --server: start compile server
    string serverSocket;          // --socket: Unix domain socket path
    int idleTimeout = 1800;       // --idle-timeout: seconds before auto-shutdown
    bool useServer = false;       // --use-server: compile via server
    
    // Debug options
    bool stackTrace = true;   // Emit call stack tracking for CTFE errors (default: on)

    // Optimization options
    bool escapeAnalysis = false;  // Enable escape analysis for stack promotion of new (default: off)
    bool arenaSafety = false;     // Enable arena safety checks (default: off)

    // Import paths
    string[] importPaths;         // -I flags for module search paths

    // Dependency graph (diagnostic)
    bool depGraph = false;        // --dep-graph: build and print dependency graph after type checking

    // FFI options
    string[] linkFrameworks;      // --link-framework: macOS frameworks to dlopen for FFI
    string[] linkDylibs;          // --link-dylib: shared libraries to dlopen for FFI

    // Libraries from pragma(lib, ...) — collected for linker
    string[] pragmaLibs;

    // Compile-only flag
    bool compileOnly = false;     // -c: compile to .o only, don't link

    // Server mode (not parsed by getopt — set programmatically by compile server)
    import server.warm_state : WarmState;
    WarmState.FileState* warmState;   // non-null when running inside compile server
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
            "target|t", "Target: wasm (default), arm64-macos", &options.target,
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
            // Server mode
            "server", "Start compile server (long-lived process)", &options.serverMode,
            "socket", "Unix domain socket path for server", &options.serverSocket,
            "idle-timeout", "Server idle timeout in seconds (default: 1800)", &options.idleTimeout,
            "use-server", "Compile via running server (auto-starts if needed)", &options.useServer,
            // Debug options
            "stack-trace", "Emit call stack tracking for CTFE errors (default: on)", &options.stackTrace,
            // Optimization options
            "escape-analysis", "Enable escape analysis for stack promotion of new (default: off)", &options.escapeAnalysis,
            "arena-safety", "Enable arena memory safety checks (default: off)", &options.arenaSafety,
            // Import paths
            "import-path", "Add import search path (can be specified multiple times)", &options.importPaths,
            // Dependency graph
            "dep-graph", "Build and print dependency graph after type checking", &options.depGraph,
            // FFI options
            "link-framework", "macOS framework to load for FFI (can be repeated)", &options.linkFrameworks,
            "link-dylib", "Shared library (.dylib) to load for FFI (can be repeated)", &options.linkDylibs,
            // Compile-only
            "c", "Compile to .o only, don't link (native targets)", &options.compileOnly
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
        
        // Server mode — no input file needed
        if (options.serverMode) {
            return runServer(options);
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
            if (options.target == "arm64-macos")
                options.outputFile = options.compileOnly
                    ? setExtension(options.inputFile, ".o")
                    : stripExtension(options.inputFile);
            else
                options.outputFile = setExtension(options.inputFile, ".wasm");
        }

        // Client mode — compile via server
        if (options.useServer) {
            return runViaServer(options);
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
        
        // 2. Parse with pluggable parser
        log(1, "Parsing source...");
        auto sourceParser = new DParser();
        Declaration[] ast;

        try {
            ast = sourceParser.parseSourceFile(options.inputFile, sourceCode);
            log(2, "Parsing successful!");
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

        // 2b. Import resolution — resolve ImportDecl nodes to modules
        import semantic.module_ : Module, ModulePhase;
        import semantic.module_registry : ModuleRegistry;
        import semantic.import_resolver : ImportResolver;
        import semantic.modules_context : ModulesContext;

        auto modRegistry = new ModuleRegistry();
        modRegistry.searchPaths = options.importPaths.dup;
        // Also search relative to the input file's directory
        modRegistry.searchPaths ~= dirName(absolutePath(options.inputFile));

        // Parse-on-demand factory shared by import resolver and runtime loading
        ParseFn parseFn = (string filename, string src) {
            return sourceParser.parseSourceFile(filename, src);
        };

        // Register runtime/object.d as its own module (implicit `import object;`)
        {
            string exeDir = dirName(thisExePath());
            string[] rtSearchPaths = [
                buildPath(exeDir, "..", "runtime", "object.d"),
                buildPath(exeDir, "runtime", "object.d"),
                "runtime/object.d",
            ];
            foreach (runtimePath; rtSearchPaths) {
                if (exists(runtimePath)) {
                    try {
                        auto rtSource = readText(runtimePath);
                        auto rtDecls = parseFn(runtimePath, rtSource);

                        auto objectMod = new Module();
                        objectMod.modulePath = ["object"];
                        objectMod.sourceFilePath = absolutePath(runtimePath);
                        objectMod.sourceText = rtSource;
                        objectMod.ast = rtDecls;
                        objectMod.phase = ModulePhase.parsed;
                        objectMod.isSynthetic = true;
                        modRegistry.registerModule(objectMod);

                        // Add synthetic `import object;` to the user's AST
                        auto objectImport = new ImportDecl(SourceLocation.init, ["object"]);
                        objectImport.resolvedModule = objectMod;
                        ast = [cast(Declaration)objectImport] ~ ast;

                        log(2, "Registered runtime module 'object' from ", runtimePath);
                    } catch (Exception e) {
                        log(1, "Warning: failed to parse runtime/object.d: ", e.msg);
                    }
                    break;
                }
            }
        }

        // Determine input module path from its AST
        string[] inputModulePath;
        foreach (decl; ast) {
            if (auto modDecl = cast(ModuleDecl)decl) {
                inputModulePath = modDecl.modulePath;
                break;
            }
        }
        if (inputModulePath.length == 0)
            inputModulePath = [baseName(stripExtension(options.inputFile))];

        auto inputModule = new Module();
        inputModule.modulePath = inputModulePath;
        inputModule.sourceFilePath = absolutePath(options.inputFile);
        inputModule.sourceText = sourceCode;
        inputModule.ast = ast;
        inputModule.phase = ModulePhase.parsed;
        modRegistry.registerModule(inputModule);

        // Scan AST for ImportDecls
        foreach (decl; ast) {
            if (auto imp = cast(ImportDecl)decl)
                inputModule.importDecls ~= imp;
        }

        // Resolve imports recursively (parse-on-demand)
        auto importResolver = new ImportResolver(modRegistry, parseFn);
        importResolver.resolveImports(inputModule);

        // Collect pragma(lib, ...) from AST — load libraries before CTFE
        {
            import core.sys.posix.dlfcn : dlopen, RTLD_LAZY, RTLD_GLOBAL;
            string sourceDir = dirName(absolutePath(options.inputFile));
            foreach (decl; ast) {
                if (auto pragma_ = cast(PragmaDeclaration)decl) {
                    if (pragma_.pragmaName == "lib") {
                        foreach (arg; pragma_.arguments) {
                            // Resolve relative paths against source file directory
                            string libPath = arg;
                            if (!isAbsolute(arg))
                                libPath = buildPath(sourceDir, arg);
                            auto handle = dlopen((libPath ~ "\0").ptr, RTLD_LAZY | RTLD_GLOBAL);
                            if (handle is null) {
                                log(1, "Warning: pragma(lib) could not load '", libPath, "'");
                            } else {
                                log(2, "Loaded pragma(lib): ", libPath);
                            }
                            options.pragmaLibs ~= libPath;
                        }
                    }
                }
            }
        }

        // Load frameworks for FFI early — before CTFE, so dlsym can find symbols
        if (options.linkFrameworks.length > 0) {
            import core.sys.posix.dlfcn : dlopen, RTLD_LAZY, RTLD_GLOBAL;
            foreach (fw; options.linkFrameworks) {
                string path = "/System/Library/Frameworks/" ~ fw ~ ".framework/" ~ fw;
                auto handle = dlopen((path ~ "\0").ptr, RTLD_LAZY | RTLD_GLOBAL);
                if (handle is null) {
                    log(1, "Warning: could not load framework '", fw, "'");
                } else {
                    log(2, "Loaded framework: ", fw);
                }
            }
        }

        // Load shared libraries for FFI — before CTFE, so dlsym can find symbols
        if (options.linkDylibs.length > 0) {
            import core.sys.posix.dlfcn : dlopen, RTLD_LAZY, RTLD_GLOBAL;
            foreach (lib; options.linkDylibs) {
                auto handle = dlopen((lib ~ "\0").ptr, RTLD_LAZY | RTLD_GLOBAL);
                if (handle is null) {
                    log(1, "Warning: could not load dylib '", lib, "'");
                } else {
                    log(2, "Loaded dylib: ", lib);
                }
            }
        }

        // ── On-demand compilation: mixin expand + symbol collect + type check ──
        import semantic.module_compiler : CompilationController;
        import semantic.mixin_expander : MixinError;

        auto controller = new CompilationController(
            modRegistry, parseFn, options.backend, options.stackTrace, options.cacheDir);

        try {
            controller.ensurePhase(inputModule, ModulePhase.typeChecked);
        } catch (MixinError e) {
            printError(e);
            return 1;
        }

        auto modulesCtx = controller.getModulesContext();
        ast = inputModule.ast;

        if (options.printAst) {
            writeln("\n=== AST (after expansion) ===");
            printAST(ast);
            writeln();
        }

        // 3. Feature validation (input module only — imported modules are trusted)
        log(1, "Running feature validation...");

        auto validator = new FeatureValidator();
        validator.validateSourceFile(ast);

        log(2, "Feature validation passed");

        if (options.onlyValidate) {
            writeln("Validation complete - no unsupported features found");
            return 0;
        }

        log(1, "Type checking passed");

        // 6b. Evaluate remaining manifest constants (for side-effect-only CTFE like enum _ = ctfeMain())
        // Lazy evaluation only triggers when values are accessed; this ensures all CTFE runs
        log(2, "Evaluating manifest constants...");
        controller.evaluateAllManifestConstants();

        // 6b2. Save manifest cache (after all CTFE is done, values are final)
        if (options.cacheDir.length > 0) {
            import cache.manifest_cache : buildManifestCache;
            foreach (mod; modulesCtx.modulesInOrder()) {
                if (mod.isSynthetic) continue;
                auto mfCache = buildManifestCache(mod.ast);
                if (mfCache.entries.length > 0) {
                    string modName = mod.modulePath.length > 0
                        ? mod.modulePath[$ - 1] : "unknown";
                    mfCache.saveToFile(
                        buildPath(options.cacheDir, modName ~ "_ctfe_cache.bin"));
                    log(2, "Saved ", mfCache.entries.length, " manifest(s) to ",
                        modName, "_ctfe_cache.bin");
                }
            }
        }

        // 6c. Dependency graph — built when --cache or --dep-graph is active
        import incremental.graph_builder : GraphBuilder;
        import incremental.dep_graph : DeclDependencyGraph;
        GraphBuilder graphBuilder;
        if (options.depGraph || options.cacheDir.length > 0) {
            log(1, "Building dependency graph...");
            graphBuilder = new GraphBuilder();

            // Build from all modules in compilation order (pass modulePath for mangled names)
            foreach (mod; modulesCtx.modulesInOrder()) {
                if (mod.sourceText.length > 0 && mod.ast.length > 0)
                    graphBuilder.build(mod.sourceFilePath, mod.sourceText, mod.ast, mod.modulePath);
            }

            if (options.depGraph)
                graphBuilder.graph.printStats();
        }

        // 6d. Arena allocation analysis
        // Determine which functions allocate (directly or transitively)
        // and mark them with needsArena for hidden parameter threading
        {
            import semantic.arena_analyzer : analyzeArenaNeeds;
            log(2, "Analyzing arena allocation needs...");
            if (options.target == "arm64-macos") {
                // Native backend compiles all modules — analyze cross-module
                Declaration[] allModuleDecls;
                foreach (mod; modulesCtx.modulesInOrder())
                    allModuleDecls ~= mod.ast;
                analyzeArenaNeeds(allModuleDecls);
            } else {
                // WASM backend: analyze user AST only (runtime functions
                // handle allocation internally without arena threading)
                analyzeArenaNeeds(ast);
            }
        }

        // 6e. Arena safety analysis (optional)
        // Checks for unsafe stores of arena-derived values (globals, cross-generation)
        if (options.arenaSafety) {
            import semantic.arena_taint : analyzeArenaSafety;
            log(2, "Analyzing arena memory safety...");
            analyzeArenaSafety(ast);
        }

        // 6f. Escape analysis (optional)
        // Stack-promotes non-escaping `new` allocations and warns on escaping &local
        if (options.escapeAnalysis) {
            import semantic.escape_analyzer : analyzeEscapes;
            log(2, "Analyzing pointer escapes...");
            analyzeEscapes(ast, inputModule.symbolTable);
        }

        // 7. Code generation
        if (!options.dryRun && options.target == "arm64-macos") {
            if (options.run) {
                // Native ARM64 JIT: compile and run directly
                log(1, "JIT compiling and running native ARM64...");

                import codegen.native.backend : NativeCompiledFunction;
                import codegen.mangle : computeMangledName;
                import codegen.target : sliceInfo, SliceInfo;

                sliceInfo = SliceInfo(8); // ARM64: 8-byte pointers

                // Collect functions and extern(C) imports from all modules
                FunctionDecl[] funcs;
                ImportedFunctionDecl[] imports;
                string entryName;

                foreach (mod; modulesCtx.modulesInOrder()) {
                foreach (decl; mod.ast) {
                    if (auto imp = cast(ImportedFunctionDecl)decl) {
                        if (imp.moduleName == "ffi")
                            imports ~= imp;
                        continue;
                    }
                    // Collect methods from struct/class declarations
                    if (auto aggDecl = cast(AggregateDecl)decl) {
                        if (auto classDecl = cast(ClassDecl)decl) {
                            if (classDecl.isObjC) {
                                // ObjC classes: only collect methods with D bodies
                                foreach (member; classDecl.members) {
                                    auto method = cast(FunctionDecl)member;
                                    if (method is null) continue;
                                    if (method.body_ is null) continue;
                                    funcs ~= method;
                                }
                                continue;
                            }
                        }
                        foreach (member; aggDecl.members) {
                            auto method = cast(FunctionDecl)member;
                            if (method is null) continue;
                            if (method.body_ is null) continue;
                            if (method.isTemplate) continue;
                            funcs ~= method;
                        }
                        continue;
                    }
                    auto funcDecl = cast(FunctionDecl)decl;
                    if (funcDecl is null) continue;
                    if (funcDecl.body_ is null) continue;
                    if (funcDecl.isTemplate) continue;

                    funcs ~= funcDecl;
                    if (funcDecl.name == options.runFunc) {
                        entryName = funcDecl.mangledName ? funcDecl.mangledName
                            : computeMangledName([], funcDecl);
                    }
                } // foreach decl
                } // foreach mod

                if (entryName.length == 0)
                    throw new Exception("No " ~ options.runFunc ~ "() function found");

                auto compiled = new NativeCompiledFunction(funcs, entryName,
                    inputModule.symbolTable, options.stackTrace, imports);
                int result = cast(int) compiled.call([]).intValue;
                compiled.dispose();

                log(1, "Exit code: ", result);

                if (options.verbosity >= 2) {
                    controller.printAllStats();
                }

                return result;
            }

            // Native ARM64 Mach-O object file output
            log(1, "Generating ARM64 Mach-O object file...");

            import codegen.native.native_emitter : NativeModuleEmitter;

            auto nativeEmitter = new NativeModuleEmitter(inputModule.symbolTable);
            ubyte[] objBytes = nativeEmitter.emit(modulesCtx);

            if (options.compileOnly) {
                // -c: write .o and stop
                std.file.write(options.outputFile, objBytes);
                log(1, "Generated ", objBytes.length, " bytes → ", options.outputFile);
                writeln("Successfully compiled to ", options.outputFile);
            } else {
                // Compile + link: write .o to temp, invoke cc to link
                string objFile = options.outputFile ~ ".o";
                std.file.write(objFile, objBytes);
                log(1, "Generated ", objBytes.length, " bytes → ", objFile);

                // Build linker command
                string[] ccArgs = ["cc", "-o", options.outputFile, objFile, "-lSystem", "-lobjc"];
                foreach (fw; options.linkFrameworks)
                    ccArgs ~= ["-framework", fw];
                foreach (lib; options.linkDylibs)
                    ccArgs ~= ["-l" ~ lib];
                foreach (lib; options.pragmaLibs) {
                    // Detect framework paths: .../Foo.framework/Foo → -framework Foo
                    import std.string : indexOf;
                    auto fwIdx = indexOf(lib, ".framework/");
                    if (fwIdx >= 0) {
                        string fwName = lib[fwIdx + 11 .. $]; // after ".framework/"
                        ccArgs ~= ["-framework", fwName];
                    } else {
                        ccArgs ~= lib;
                    }
                }

                import std.process : execute;
                log(1, "Linking: ", ccArgs);
                auto result = execute(ccArgs);
                if (result.status != 0) {
                    writeln("Linker error:\n", result.output);
                    return 1;
                }

                // Clean up temp .o
                std.file.remove(objFile);

                writeln("Successfully compiled to ", options.outputFile);
            }

            // Print CTFE stats at verbosity 2+
            if (options.verbosity >= 2) {
                controller.printAllStats();
            }

            return 0;
        }

        if (!options.dryRun) {
            log(1, "Generating binary WASM...");

            // Set target slice layout before codegen
            {
                import codegen.target : sliceInfo, SliceInfo;
                sliceInfo = SliceInfo(inputModule.symbolTable.targetPtrSize);
            }

            auto emitter = new BinaryEmitter(inputModule.symbolTable, options.stackTrace);
            
            // Load cache if enabled (warm state from server, or disk-based)
            import cache.compiler_cache : CompilerCache;
            import cache.entry : CacheEntry;
            import server.warm_state : WarmState;
            CompilerCache cache;
            bool usingWarmState = options.warmState !is null;

            if (usingWarmState) {
                // ── Server mode: use in-memory warm state ──
                emitter.setSourceText(sourceCode);

                auto ws = options.warmState;
                if (ws.cachedEntries.length > 0) {
                    emitter.setCodeCache(ws.cachedEntries);
                    log(2, "Warm state: ", ws.cachedEntries.length, " cached function(s)");
                }

                // Dep-graph invalidation using warm state's graph as the "old" graph
                if (graphBuilder !is null && ws.depGraph !is null) {
                    invalidateFromDepGraph(ws.depGraph, graphBuilder, emitter);
                }
            } else if (options.cacheDir.length > 0) {
                // ── Disk mode: load from CompilerCache ──
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

                // Dep-graph-based cache invalidation from disk
                if (graphBuilder !is null) {
                    string graphPath = buildPath(options.cacheDir, moduleName ~ "_dep_graph.bin");
                    auto oldGraph = DeclDependencyGraph.loadFromFile(graphPath);
                    if (oldGraph !is null) {
                        invalidateFromDepGraph(oldGraph, graphBuilder, emitter);
                    }

                    // Save new graph for next run
                    graphBuilder.graph.saveToFile(graphPath);
                    log(2, "Saved ", moduleName, "_dep_graph.bin (", graphBuilder.graph.serialize().length, " bytes)");
                }
            }

            ubyte[] wasm = emitter.emit(modulesCtx);
            
            if (wasm is null) {
                import diagnostic.error_format : formatError;
                auto loc = emitter.errorLocation();
                if (loc.line > 0) {
                    stderr.write(formatError("CodeGen", emitter.error(), loc));
                } else {
                    stderr.writeln("error: ", emitter.error());
                }
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

                // Frameworks already loaded earlier (before CTFE) via dlopen

                import semantic.ctfe_runtime : CTFERuntime;
                auto wasmFromFile = cast(ubyte[])std.file.read(options.outputFile);

                auto runner = new CTFERuntime();
                runner.loadModule(wasmFromFile);
                
                string runTarget = emitter.resolveExportName(options.runFunc);
                int result = runner.callI32(runTarget).asInt();
                log(1, "Exit code: ", result);
                
                // Print CTFE stats at verbosity 2+
                if (options.verbosity >= 2) {
                    controller.printAllStats();
                }
                
                return result;
            }
            
            // 9. Cache storage
            auto emitterStats = emitter.getCacheStats();

            if (usingWarmState) {
                // ── Server mode: update warm state in memory ──
                auto ws = options.warmState;
                ws.cachedEntries = emitter.getEmittedCode();
                if (graphBuilder !is null)
                    ws.depGraph = graphBuilder.graph;
                ws.lastCacheHits = emitterStats.cacheHits;
                ws.lastCacheMisses = emitterStats.cacheMisses;
                log(2, "Warm state updated: ", emitterStats.cacheHits, " hits, ",
                    emitterStats.cacheMisses, " misses");
            } else if (cache !is null) {
                // ── Disk mode: flush to staging file ──
                import std.json;

                auto emittedCode = emitter.getEmittedCode();
                cache.storeEntries(emittedCode);
                cache.flush();

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
            
            if (!usingWarmState)
                writeln("Successfully compiled to ", options.outputFile);
        } else {
            writeln("Dry run complete - frontend phases successful");
        }
        
        // Print CTFE stats at verbosity 2+
        if (options.verbosity >= 2) {
            controller.printAllStats();
        }
        
        return 0;
        
    } catch (ImportError e) {
        printError(e);
        return 1;
    } catch (ParseError e) {
        printError(e);
        return 1;
    } catch (FeatureValidationError e) {
        printError(e);
        return 1;
    } catch (SemanticError e) {
        printError(e);
        return 1;
    } catch (ArenaSafetyError e) {
        // Individual errors already printed with formatError in analyzeArenaSafety
        return 1;
    } catch (TypeError e) {
        printError(e);
        return 1;
    } catch (CTFEError e) {
        printError(e);
        return 1;
    } catch (EmitError e) {
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
 * Dep-graph invalidation: compare old graph against new graph to find
 * transitively dirty functions, then evict them from the emitter's code cache.
 * Shared by both disk-based and warm-state cache paths.
 */
private void invalidateFromDepGraph(
    DeclDependencyGraph oldGraph,
    GraphBuilder graphBuilder,
    BinaryEmitter emitter)
{
    import diagnostic.log : log;

    ulong[string] oldMangledHash;
    ulong[string] oldNameKindHash;
    foreach (ref n; oldGraph.nodes) {
        if (n.mangledName.length > 0)
            oldMangledHash[n.mangledName] = n.sourceHash;
        else
            oldNameKindHash[n.name ~ "\0" ~ n.kind] = n.sourceHash;
    }

    auto changedIds = appender!(uint[]);
    auto newGraph = graphBuilder.graph;
    foreach (ref n; newGraph.nodes) {
        bool changed = false;
        if (n.mangledName.length > 0) {
            auto p = n.mangledName in oldMangledHash;
            changed = (p is null || *p != n.sourceHash);
        } else {
            auto key = n.name ~ "\0" ~ n.kind;
            auto p = key in oldNameKindHash;
            changed = (p is null || *p != n.sourceHash);
        }
        if (changed)
            changedIds ~= n.id;
    }

    if (changedIds[].length > 0) {
        auto dirtyIds = newGraph.invalidate(changedIds[]);

        auto dirtyNames = appender!(string[]);
        foreach (did; dirtyIds) {
            auto node = newGraph.getNode(did);
            if (node !is null && node.mangledName.length > 0)
                dirtyNames ~= node.mangledName;
        }

        if (dirtyNames[].length > 0) {
            emitter.evictFromCache(dirtyNames[]);
            log(2, "Dep-graph invalidation: evicted ",
                dirtyNames[].length, " function(s) from cache");
        }
    }
}

/**
 * Start the compile server (long-lived process).
 */
int runServer(CompilerOptions options) {
    import server.compile_server : CompileServer;

    // Default socket path
    string socketPath = options.serverSocket.length > 0
        ? options.serverSocket
        : ".d2wasm-cache/compile-server.sock";

    auto server = new CompileServer(
        socketPath,
        options.backend,
        options.verbosity,
        options.stackTrace,
        options.escapeAnalysis,
        options.arenaSafety,
        options.importPaths,
        options.idleTimeout
    );

    return server.run();
}

/**
 * Compile via a running server. Auto-starts the server if not running.
 */
int runViaServer(CompilerOptions options) {
    import server.client : compileViaServer;
    return compileViaServer(options);
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