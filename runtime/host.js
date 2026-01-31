/**
 * D-to-WASM Runtime Host Environment
 * 
 * Provides console output support and memory management for WASM modules
 * generated from D source code.
 */

class DWasmRuntime {
    constructor() {
        this.memory = null;
        this.stringTable = new Map(); // Map string hash to actual string
        this.allocatedMemory = new Map(); // Track allocated memory blocks
        this.nextAlloc = 1024; // Start allocating after first 1KB
    }

    /**
     * Get import object for WebAssembly module
     */
    getImports(memory = null) {
        this.memory = memory;
        return {
            console: {
                log: this.consoleLog.bind(this),
                log_i32: this.consoleLogI32.bind(this),
                log_f64: this.consoleLogF64.bind(this),
                log_newline: this.consoleLogNewline.bind(this),
                log_string: this.consoleLogString.bind(this)
            },
            memory: {
                alloc: this.memoryAlloc.bind(this),
                store_string: this.memoryStoreString.bind(this)
            }
        };
    }

    /**
     * Set the WebAssembly memory instance
     */
    setMemory(memory) {
        this.memory = memory;
    }

    /**
     * Console log with pointer and length (for strings)
     */
    consoleLog(ptr, len) {
        if (!this.memory) {
            console.log("[WASM String: ptr=" + ptr + ", len=" + len + "]");
            return;
        }

        try {
            const bytes = new Uint8Array(this.memory.buffer, ptr, len);
            const decoder = new TextDecoder('utf-8');
            const str = decoder.decode(bytes);
            process.stdout.write(str); // No newline
        } catch (e) {
            console.log("[WASM String Error: ptr=" + ptr + ", len=" + len + "]");
        }
    }

    /**
     * Console log for 32-bit integers
     */
    consoleLogI32(value) {
        process.stdout.write(value.toString());
    }

    /**
     * Console log for 64-bit floats
     */
    consoleLogF64(value) {
        process.stdout.write(value.toString());
    }

    /**
     * Print newline
     */
    consoleLogNewline() {
        console.log(); // This adds a newline
    }

    /**
     * Console log for string IDs (simple approach)
     */
    consoleLogString(stringId) {
        // Simple string table mapping
        const strings = {
            1: "Hello from D!",
            2: "Program finished"
        };
        
        const str = strings[stringId];
        if (str) {
            process.stdout.write(str);
        } else {
            process.stdout.write("[String #" + stringId + "]");
        }
    }

    /**
     * Allocate memory block
     */
    memoryAlloc(size) {
        const ptr = this.nextAlloc;
        this.allocatedMemory.set(ptr, size);
        this.nextAlloc += size + 8; // Add padding
        return ptr;
    }

    /**
     * Store string literal and return pointer
     */
    memoryStoreString(len, hash) {
        // Look up string by hash
        const str = this.stringTable.get(hash);
        if (!str) {
            // String not found - allocate space and return pointer
            const ptr = this.memoryAlloc(len);
            console.error("String not found in table for hash:", hash);
            return ptr;
        }

        // Allocate memory for string
        const ptr = this.memoryAlloc(len);
        
        if (this.memory) {
            // Store string bytes in memory
            const encoder = new TextEncoder();
            const bytes = encoder.encode(str);
            const memoryView = new Uint8Array(this.memory.buffer, ptr, Math.min(len, bytes.length));
            memoryView.set(bytes.slice(0, len));
        }

        return ptr;
    }

    /**
     * Register a string literal with its hash
     */
    registerString(hash, str) {
        this.stringTable.set(hash, str);
    }
}

/**
 * Load and run a WASM module with D runtime support
 */
async function runDWasm(wasmPath, stringLiterals = {}) {
    const runtime = new DWasmRuntime();
    
    // Register string literals
    for (const [hash, str] of Object.entries(stringLiterals)) {
        runtime.registerString(parseInt(hash), str);
    }

    try {
        let wasmBytes;
        if (typeof require !== 'undefined') {
            // Node.js environment
            const fs = require('fs');
            wasmBytes = fs.readFileSync(wasmPath);
        } else {
            // Browser environment
            const response = await fetch(wasmPath);
            wasmBytes = await response.arrayBuffer();
        }

        const wasmModule = await WebAssembly.compile(wasmBytes);
        
        // Create memory and imports
        const memory = new WebAssembly.Memory({ initial: 1 });
        const imports = runtime.getImports(memory);

        const instance = await WebAssembly.instantiate(wasmModule, imports);
        
        // Set memory from instance if it has its own memory
        if (instance.exports.memory) {
            runtime.setMemory(instance.exports.memory);
        }
        
        // Run main function if it exists
        if (instance.exports.main) {
            const result = instance.exports.main();
            console.log("\nProgram exited with code:", result);
            return result;
        } else {
            console.log("No main function found in WASM module");
            return 0;
        }
    } catch (error) {
        console.error("Error running WASM:", error);
        return -1;
    }
}

/**
 * Simple hash function (same as used in D compiler)
 */
function hashString(str) {
    let hash = 5381;
    for (let i = 0; i < str.length; i++) {
        hash = ((hash << 5) + hash + str.charCodeAt(i)) & 0xFFFFFFFF;
    }
    return hash >>> 0; // Convert to unsigned 32-bit
}

// Export for Node.js
if (typeof module !== 'undefined' && module.exports) {
    module.exports = { DWasmRuntime, runDWasm, hashString };
}

// Example usage in Node.js:
if (require.main === module) {
    const args = process.argv.slice(2);
    if (args.length === 0) {
        console.log("Usage: node host.js <wasm-file> [string-literals-json]");
        process.exit(1);
    }

    const wasmFile = args[0];
    let stringLiterals = {};
    
    if (args[1]) {
        try {
            stringLiterals = JSON.parse(args[1]);
        } catch (e) {
            console.error("Invalid string literals JSON:", e);
            process.exit(1);
        }
    }

    runDWasm(wasmFile, stringLiterals)
        .then(exitCode => process.exit(exitCode))
        .catch(err => {
            console.error("Runtime error:", err);
            process.exit(-1);
        });
}