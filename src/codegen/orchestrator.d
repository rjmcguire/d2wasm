/**
 * Compilation Orchestrator
 * 
 * Manages parallel compilation of multiple source files using child processes.
 * Each file is compiled in a separate process for crash isolation.
 * 
 * Flow:
 *   1. Parent spawns child process per input file
 *   2. Each child compiles to WASM + writes staging file
 *   3. Parent waits for all children
 *   4. On success: merge staging files into main.db
 *   5. On failure: leave staging files for cleanup
 */
module codegen.orchestrator;

import std.process;
import std.file;
import std.path;
import std.stdio;
import std.json;
import std.array;
import std.algorithm;
import std.conv;
import std.parallelism;

/// Result from compiling a single file
struct CompileResult {
    string inputFile;
    string outputFile;
    bool success;
    int exitCode;
    string error;
    size_t cacheHits;
    size_t cacheMisses;
    size_t wasmSize;
}

/// Aggregate results from parallel compilation
struct OrchestratorResult {
    CompileResult[] results;
    size_t totalFiles;
    size_t successCount;
    size_t failCount;
    size_t totalCacheHits;
    size_t totalCacheMisses;
    
    bool allSucceeded() const {
        return failCount == 0;
    }
}

/**
 * Orchestrator for parallel compilation.
 */
class Orchestrator {
    private {
        string compilerPath;
        string cacheDir;
        string outputDir;
        int maxParallel;
        bool jsonOutput;
        int verbosity;
    }
    
    /**
     * Initialize the orchestrator.
     * 
     * Params:
     *   compilerPath = Path to the d2wasm executable
     *   cacheDir = Directory for cache files (optional)
     *   outputDir = Directory for output WASM files
     *   maxParallel = Maximum parallel compilations (0 = auto)
     */
    this(string compilerPath, string cacheDir = null, 
         string outputDir = ".", int maxParallel = 0) {
        this.compilerPath = compilerPath;
        this.cacheDir = cacheDir;
        this.outputDir = outputDir;
        this.maxParallel = maxParallel > 0 ? maxParallel : totalCPUs;
        this.jsonOutput = true;  // Always use JSON for child output
    }
    
    /**
     * Set verbosity level for child processes.
     */
    void setVerbosity(int level) {
        this.verbosity = level;
    }
    
    /**
     * Compile multiple files in parallel.
     */
    OrchestratorResult compile(string[] inputFiles) {
        OrchestratorResult result;
        result.totalFiles = inputFiles.length;
        
        // Create output directory if needed
        if (outputDir.length > 0 && !exists(outputDir)) {
            mkdirRecurse(outputDir);
        }
        
        // Compile in parallel using task pool
        auto pool = new TaskPool(maxParallel);
        scope(exit) pool.stop();
        
        CompileResult[] results;
        results.length = inputFiles.length;
        
        foreach (i, inputFile; pool.parallel(inputFiles)) {
            results[i] = compileOne(inputFile);
        }
        
        // Aggregate results
        result.results = results;
        foreach (r; results) {
            if (r.success) {
                result.successCount++;
            } else {
                result.failCount++;
            }
            result.totalCacheHits += r.cacheHits;
            result.totalCacheMisses += r.cacheMisses;
        }
        
        // Merge staging files if using cache and all succeeded
        if (cacheDir.length > 0 && result.allSucceeded()) {
            mergeStagingFiles();
        }
        
        return result;
    }
    
    /**
     * Compile a single file via child process.
     */
    private CompileResult compileOne(string inputFile) {
        CompileResult result;
        result.inputFile = inputFile;
        
        // Determine output file
        string baseName = std.path.baseName(stripExtension(inputFile));
        result.outputFile = buildPath(outputDir, baseName ~ ".wasm");
        
        // Build command
        string[] cmd = [compilerPath];
        cmd ~= inputFile;
        cmd ~= "-o";
        cmd ~= result.outputFile;
        
        if (cacheDir.length > 0) {
            cmd ~= "--cache=" ~ cacheDir;
        }
        
        cmd ~= "--json";  // Always get JSON output from child
        
        // Add verbosity flags
        foreach (_; 0 .. verbosity) {
            cmd ~= "-v";
        }
        
        // Execute child process
        try {
            auto pipes = pipeProcess(cmd, Redirect.stdout | Redirect.stderr);
            
            // Collect output
            string stdout_data;
            foreach (line; pipes.stdout.byLine) {
                stdout_data ~= line.idup ~ "\n";
            }
            
            string stderr_data;
            foreach (line; pipes.stderr.byLine) {
                stderr_data ~= line.idup ~ "\n";
            }
            
            auto status = wait(pipes.pid);
            result.exitCode = status;
            result.success = (status == 0);
            
            if (!result.success) {
                result.error = stderr_data.length > 0 ? stderr_data : stdout_data;
            } else {
                // Parse JSON output
                try {
                    auto json = parseJSON(stdout_data);
                    result.cacheHits = json["cacheHits"].get!size_t;
                    result.cacheMisses = json["cacheMisses"].get!size_t;
                    result.wasmSize = json["wasmSize"].get!size_t;
                } catch (Exception e) {
                    // JSON parsing failed, but compilation succeeded
                }
            }
            
        } catch (Exception e) {
            result.success = false;
            result.error = "Failed to execute compiler: " ~ e.msg;
            result.exitCode = -1;
        }
        
        return result;
    }
    
    /**
     * Merge staging files into main database.
     */
    private void mergeStagingFiles() {
        if (cacheDir.length == 0) return;
        
        import cache.maindb : MainDatabase;
        
        string dbPath = buildPath(cacheDir, "main.db");
        string stagingDir = buildPath(cacheDir, "staging");
        
        auto db = new MainDatabase(dbPath);
        db.mergeFromStaging(stagingDir);
    }
}

//==============================================================================
// Unit Tests
//==============================================================================

unittest {
    import std.stdio : writeln;
    
    // Test CompileResult initialization
    CompileResult r;
    assert(!r.success);
    assert(r.exitCode == 0);
    
    writeln("✓ Orchestrator CompileResult test passed");
}

unittest {
    import std.stdio : writeln;
    
    // Test OrchestratorResult aggregation
    OrchestratorResult r;
    r.totalFiles = 3;
    r.successCount = 2;
    r.failCount = 1;
    
    assert(!r.allSucceeded());
    
    r.failCount = 0;
    r.successCount = 3;
    assert(r.allSucceeded());
    
    writeln("✓ Orchestrator OrchestratorResult test passed");
}
