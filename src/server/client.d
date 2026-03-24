/**
 * Compile Server Client
 *
 * Sends compile requests to a running compile server.
 * Auto-starts the server if not running.
 */
module server.client;

import std.stdio;
import std.socket;
import std.string;
import std.json;
import std.file;
import std.path;
import std.conv;
import std.process;
import core.thread;
import core.time;

import main : CompilerOptions;

/// Compile a file via the compile server.
/// Returns the exit code (0 = success).
int compileViaServer(CompilerOptions options) {
    string socketPath = options.serverSocket.length > 0
        ? options.serverSocket
        : ".d2wasm-cache/compile-server.sock";

    // Try to connect; if server isn't running, start it
    Socket sock;
    try {
        sock = connectToServer(socketPath);
    } catch (Exception) {
        // Auto-start server
        if (!startServer(socketPath, options)) {
            stderr.writeln("Error: failed to start compile server");
            return 1;
        }
        // Wait for server to be ready
        sock = waitForServer(socketPath, 5);
        if (sock is null) {
            stderr.writeln("Error: compile server did not start in time");
            return 1;
        }
    }

    scope(exit) sock.close();

    // Build compile request
    JSONValue req;
    req["id"] = 1;
    req["method"] = "compile";

    JSONValue params;
    params["file"] = options.inputFile;
    if (options.outputFile.length > 0)
        params["output"] = options.outputFile;
    if (options.importPaths.length > 0) {
        JSONValue[] paths;
        foreach (p; options.importPaths)
            paths ~= JSONValue(p);
        params["importPaths"] = paths;
    }
    req["params"] = params;

    // Send request
    string reqLine = req.toString() ~ "\n";
    sock.send(cast(const(ubyte)[])reqLine);

    // Read response
    string response = readLine(sock);
    if (response.length == 0) {
        stderr.writeln("Error: no response from server");
        return 1;
    }

    // Parse response
    try {
        auto json = parseJSON(response);

        if ("error" in json) {
            auto err = json["error"];
            stderr.writeln("Error: ", err["message"].str);
            return 1;
        }

        if ("result" in json) {
            auto result = json["result"];
            bool success = result["success"].get!bool;

            if (success) {
                auto wasmSize = result["wasmSize"].get!long;
                auto hits = result["cacheHits"].get!long;
                auto misses = result["cacheMisses"].get!long;
                auto timeMs = result["timeMs"].get!long;

                if (options.jsonOutput) {
                    writeln(result.toPrettyString());
                } else {
                    writeln("Compiled via server: ", options.outputFile,
                            " (", wasmSize, " bytes, ",
                            hits, " hits, ", misses, " misses, ",
                            timeMs, "ms)");
                }
                return 0;
            } else {
                stderr.writeln("Compilation failed");
                return 1;
            }
        }
    } catch (Exception e) {
        stderr.writeln("Error parsing server response: ", e.msg);
        return 1;
    }

    return 1;
}

private Socket connectToServer(string socketPath) {
    auto sock = new Socket(AddressFamily.UNIX, SocketType.STREAM);
    sock.connect(new UnixAddress(socketPath));
    return sock;
}

private bool startServer(string socketPath, CompilerOptions options) {
    import core.runtime : Runtime;

    string compilerPath = Runtime.args[0];

    string[] args = [compilerPath, "--server"];
    if (socketPath != ".d2wasm-cache/compile-server.sock")
        args ~= "--socket=" ~ socketPath;
    if (options.backend != "wasm")
        args ~= "--backend=" ~ options.backend;
    foreach (p; options.importPaths)
        args ~= "--import-path=" ~ p;

    try {
        // Spawn server in background
        auto pid = spawnProcess(args,
            std.stdio.stdin,
            std.stdio.File("/dev/null", "w"),  // stdout
            std.stdio.stderr);                  // stderr stays visible
        return true;
    } catch (Exception) {
        return false;
    }
}

private Socket waitForServer(string socketPath, int timeoutSec) {
    foreach (i; 0 .. timeoutSec * 10) {
        Thread.sleep(dur!"msecs"(100));
        try {
            return connectToServer(socketPath);
        } catch (Exception) {
            continue;
        }
    }
    return null;
}

private string readLine(Socket sock) {
    char[] buf;
    buf.length = 4096;
    string accum;

    sock.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"seconds"(30));

    while (true) {
        ptrdiff_t n;
        try {
            n = sock.receive(buf);
        } catch (SocketOSException) {
            break;
        }
        if (n <= 0)
            break;

        accum ~= cast(string)buf[0 .. n];
        auto nlPos = accum.indexOf('\n');
        if (nlPos >= 0)
            return accum[0 .. nlPos];
    }

    return accum;
}
