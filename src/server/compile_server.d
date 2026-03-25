/**
 * Compile Server
 *
 * A long-lived process that accepts compilation requests over a Unix domain
 * socket, keeping the code cache and dependency graph warm in memory across
 * compilations. This avoids process startup overhead and disk I/O for the
 * cache on every edit-compile cycle.
 *
 * Protocol: NDJSON (newline-delimited JSON) over Unix domain socket.
 * See protocol.d for message format.
 */
module server.compile_server;

import std.stdio;
import std.socket;
import std.string;
import std.file;
import std.path;
import std.conv;
import std.json;
import std.array;
import core.time : MonoTime, dur;

import server.protocol;
import server.warm_state;

class CompileServer {
    private {
        string socketPath;
        string pidPath;
        WarmState warmState;
        Socket listener;
        bool running;
        int idleTimeoutSec;
        MonoTime lastActivity;

        // Base options from command line (file/output overridden per request)
        string backend;
        int verbosity;
        bool stackTrace;
        bool escapeAnalysis;
        bool arenaSafety;
        string[] defaultImportPaths;
    }

    this(string socketPath, string backend, int verbosity,
         bool stackTrace, bool escapeAnalysis, bool arenaSafety,
         string[] importPaths, int idleTimeoutSec = 1800)
    {
        this.socketPath = socketPath;
        this.pidPath = socketPath.stripExtension ~ ".pid";
        this.backend = backend;
        this.verbosity = verbosity;
        this.stackTrace = stackTrace;
        this.escapeAnalysis = escapeAnalysis;
        this.arenaSafety = arenaSafety;
        this.defaultImportPaths = importPaths;
        this.idleTimeoutSec = idleTimeoutSec;
        this.warmState = new WarmState();
        this.lastActivity = MonoTime.currTime;
    }

    /// Start listening and enter the event loop.
    int run() {
        if (!bind())
            return 1;

        writePidFile();
        running = true;
        scope(exit) cleanup();

        serverLog("Compile server started");
        serverLog("  Socket: ", socketPath);
        serverLog("  Backend: ", backend);
        serverLog("  Idle timeout: ", idleTimeoutSec, "s");

        eventLoop();
        return 0;
    }

    private bool bind() {
        // Remove stale socket if it exists
        if (exists(socketPath)) {
            // Try to connect — if it succeeds, another server is running
            try {
                auto testSock = new Socket(AddressFamily.UNIX, SocketType.STREAM);
                testSock.connect(new UnixAddress(socketPath));
                testSock.close();
                stderr.writeln("Error: another compile server is already running at ", socketPath);
                return false;
            } catch (SocketOSException) {
                // Connection refused — stale socket, safe to remove
                std.file.remove(socketPath);
            }
        }

        // Ensure parent directory exists
        string dir = dirName(socketPath);
        if (dir.length > 0 && !exists(dir))
            mkdirRecurse(dir);

        listener = new Socket(AddressFamily.UNIX, SocketType.STREAM);
        listener.blocking = true;
        listener.bind(new UnixAddress(socketPath));
        listener.listen(4);

        // Set a timeout on accept so we can check idle timeout periodically
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"seconds"(5));

        return true;
    }

    private void writePidFile() {
        import std.process : thisProcessID;
        std.file.write(pidPath, to!string(thisProcessID()));
    }

    private void cleanup() {
        serverLog("Shutting down...");
        if (listener !is null) {
            listener.close();
            listener = null;
        }
        if (exists(socketPath))
            std.file.remove(socketPath);
        if (exists(pidPath))
            std.file.remove(pidPath);
        serverLog("Stopped.");
    }

    private void eventLoop() {
        while (running) {
            // Check idle timeout
            auto elapsed = MonoTime.currTime - lastActivity;
            if (elapsed > dur!"seconds"(idleTimeoutSec)) {
                serverLog("Idle timeout (", idleTimeoutSec, "s), shutting down");
                break;
            }

            Socket client;
            try {
                client = listener.accept();
            } catch (SocketOSException) {
                // accept timed out — loop back to check idle
                continue;
            }

            if (client is null)
                continue;

            lastActivity = MonoTime.currTime;
            handleConnection(client);
        }
    }

    private void handleConnection(Socket client) {
        scope(exit) client.close();

        // Read lines from client
        char[] buffer;
        buffer.length = 64 * 1024;
        string leftover;

        // Set read timeout on client socket
        client.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"seconds"(30));

        while (running) {
            // Try to extract a complete line from leftover
            auto nlPos = leftover.indexOf('\n');
            if (nlPos >= 0) {
                string line = leftover[0 .. nlPos];
                leftover = leftover[nlPos + 1 .. $];

                string response = handleRequest(line);
                if (response.length > 0)
                    sendAll(client, response);

                if (!running)
                    break;
                continue;
            }

            // Need more data
            ptrdiff_t received;
            try {
                received = client.receive(buffer);
            } catch (SocketOSException) {
                break; // timeout or error
            }

            if (received <= 0)
                break; // client disconnected

            leftover ~= cast(string)buffer[0 .. received];
        }
    }

    private void sendAll(Socket sock, string data) {
        auto bytes = cast(const(ubyte)[])data;
        while (bytes.length > 0) {
            auto sent = sock.send(bytes);
            if (sent <= 0) break;
            bytes = bytes[sent .. $];
        }
    }

    private string handleRequest(string line) {
        if (line.length == 0)
            return "";

        auto req = parseRequest(line);

        final switch (req.method) {
            case Method.compile:
                return handleCompile(req);
            case Method.fileChanged:
                return handleFileChanged(req);
            case Method.status:
                return handleStatus(req);
            case Method.shutdown:
                return handleShutdown(req);
            case Method.unknown:
                return serializeError(req.id, "UNKNOWN_METHOD", "Unknown or malformed request");
        }
    }

    private string handleCompile(Request req) {
        import main : CompilerOptions, compileFile;
        import cache.entry : CacheEntry;
        import incremental.dep_graph : DeclDependencyGraph;

        if (req.file.length == 0)
            return serializeError(req.id, "INVALID_PARAMS", "Missing 'file' parameter");

        auto startTime = MonoTime.currTime;
        string absFile = absolutePath(req.file);

        // Build CompilerOptions from request + server defaults
        CompilerOptions options;
        options.inputFile = req.file;
        string reqTarget = req.target.length > 0 ? req.target : "wasm";
        options.target = reqTarget;
        if (reqTarget == "arm64-macos") {
            options.outputFile = req.output.length > 0
                ? req.output
                : (options.compileOnly
                    ? setExtension(req.file, ".o")
                    : stripExtension(req.file));
            options.compileOnly = req.output.length > 0
                ? req.output.endsWith(".o")
                : true;  // default to compile-only for native via server
        } else {
            options.outputFile = req.output.length > 0
                ? req.output
                : setExtension(req.file, ".wasm");
        }
        options.backend = backend;
        options.verbosity = verbosity;
        options.stackTrace = stackTrace;
        options.escapeAnalysis = escapeAnalysis;
        options.arenaSafety = arenaSafety;
        options.importPaths = req.importPaths.length > 0
            ? req.importPaths.dup
            : defaultImportPaths.dup;

        // Inject warm state: use in-memory cache dir so compileFile
        // activates the cache path, but we provide entries from warm state
        options.cacheDir = socketPath.dirName;
        auto ws = warmState.getOrCreate(absFile);
        options.warmState = ws;
        options.warmStateObj = warmState;  // project-level (module registry)

        // Apply pending dirty names from incremental fileChanged (Phase 2)
        // These were pre-computed via tree-sitter changed ranges + dep graph
        if (ws.pendingDirtyNames.length > 0) {
            options.pendingEvictions = ws.pendingDirtyNames;
            ws.pendingDirtyNames = null;
            serverLog("Compiling: ", req.file, " (", options.pendingEvictions.length, " pre-evicted)");
        } else {
            serverLog("Compiling: ", req.file);
        }

        // Pass changed byte ranges for selective re-type-check (Phase 4)
        if (ws.pendingChangedRanges.length > 0) {
            options.changedRanges = ws.pendingChangedRanges;
            ws.pendingChangedRanges = null;
        }

        // Run compilation
        int exitCode = compileFile(options);

        auto elapsed = MonoTime.currTime - startTime;
        long timeMs = elapsed.total!"msecs";

        warmState.compilations++;
        lastActivity = MonoTime.currTime;

        // Build response
        CompileResult result;
        if (exitCode == 0) {
            result.success = true;
            result.output = options.outputFile;
            result.timeMs = timeMs;

            // Read stats from warm state (written by compileFile via pointer)
            auto fs = warmState.getOrCreate(absFile);
            result.cacheHits = fs.lastCacheHits;
            result.cacheMisses = fs.lastCacheMisses;

            if (exists(options.outputFile))
                result.wasmSize = getSize(options.outputFile);

            serverLog("  OK: ", timeMs, "ms, ",
                      result.cacheHits, " hits, ",
                      result.cacheMisses, " misses, ",
                      result.wasmSize, " bytes");
        } else {
            result.success = false;
            result.error = "Compilation failed (exit code " ~ to!string(exitCode) ~ ")";
            result.timeMs = timeMs;
            serverLog("  FAIL: ", timeMs, "ms");
        }

        return serializeCompileResponse(req.id, result);
    }

    private string handleFileChanged(Request req) {
        import parser.tree_sitter_c : TSInputEdit, TSPoint;

        if (req.file.length == 0)
            return serializeError(req.id, "INVALID_PARAMS", "Missing 'file' parameter");

        if (req.newText.length == 0)
            return serializeError(req.id, "INVALID_PARAMS", "Missing 'newText' parameter");

        string absFile = absolutePath(req.file);

        // Build TSInputEdit if incremental edit descriptor provided
        TSInputEdit* editPtr = null;
        TSInputEdit edit;
        if (req.hasEdit) {
            edit.start_byte = req.editStartByte;
            edit.old_end_byte = req.editOldEndByte;
            edit.new_end_byte = req.editNewEndByte;
            edit.start_point = TSPoint(req.editStartLine, req.editStartCol);
            edit.old_end_point = TSPoint(req.editOldEndLine, req.editOldEndCol);
            edit.new_end_point = TSPoint(req.editNewEndLine, req.editNewEndCol);
            editPtr = &edit;
        }

        auto directlyAffected = warmState.applyFileChange(absFile, req.newText, editPtr);

        auto fs = warmState.getOrCreate(absFile);
        if (req.hasEdit && directlyAffected > 0) {
            serverLog("Incremental change: ", req.file, " — ",
                      directlyAffected, " declaration(s) affected, ",
                      fs.pendingDirtyNames.length, " transitively dirty");
        } else {
            serverLog("Updated source: ", req.file, " (", req.newText.length, " chars)");
        }

        lastActivity = MonoTime.currTime;
        return serializeAck(req.id);
    }

    private string handleStatus(Request req) {
        StatusResult status;
        status.cachedFunctions = warmState.totalCachedEntries();
        status.depGraphLoaded = warmState.hasAnyDepGraph();
        status.compilations = warmState.compilations;
        return serializeStatusResponse(req.id, status);
    }

    private string handleShutdown(Request req) {
        serverLog("Shutdown requested");
        running = false;
        return serializeAck(req.id);
    }

    private void serverLog(T...)(T args) {
        import std.datetime : Clock;
        auto now = Clock.currTime();
        stderr.writef("[%02d:%02d:%02d] ", now.hour, now.minute, now.second);
        stderr.writeln(args);
        stderr.flush();
    }
}
