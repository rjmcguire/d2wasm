/**
 * Compile Server Protocol
 *
 * NDJSON-based request/response protocol over Unix domain socket.
 * Each message is a single JSON object terminated by '\n'.
 */
module server.protocol;

import std.json;
import std.conv : to;

/// Request methods
enum Method {
    compile,
    fileChanged,
    status,
    shutdown,
    unknown
}

/// Parsed request from client
struct Request {
    int id;
    Method method;

    // compile params
    string file;
    string output;
    string[] importPaths;

    // fileChanged params
    string newText;

    // Raw JSON for extensibility
    JSONValue raw;
}

/// Compile result sent back to client
struct CompileResult {
    bool success;
    string output;        // output file path
    size_t wasmSize;
    size_t cacheHits;
    size_t cacheMisses;
    long timeMs;
    string error;         // error message if !success
}

/// Status result
struct StatusResult {
    size_t cachedFunctions;
    bool depGraphLoaded;
    size_t compilations;
}

/// Parse a JSON request line
Request parseRequest(string line) {
    Request req;
    req.method = Method.unknown;

    try {
        auto json = parseJSON(line);
        req.raw = json;

        if ("id" in json)
            req.id = json["id"].get!int;

        if ("method" in json) {
            switch (json["method"].str) {
                case "compile":     req.method = Method.compile; break;
                case "fileChanged": req.method = Method.fileChanged; break;
                case "status":      req.method = Method.status; break;
                case "shutdown":    req.method = Method.shutdown; break;
                default:            req.method = Method.unknown; break;
            }
        }

        if ("params" in json) {
            auto params = json["params"];
            if ("file" in params)
                req.file = params["file"].str;
            if ("output" in params)
                req.output = params["output"].str;
            if ("newText" in params)
                req.newText = params["newText"].str;
            if ("importPaths" in params) {
                foreach (p; params["importPaths"].array)
                    req.importPaths ~= p.str;
            }
        }
    } catch (Exception) {
        req.method = Method.unknown;
    }

    return req;
}

/// Serialize a compile response
string serializeCompileResponse(int id, CompileResult result) {
    JSONValue json;
    json["id"] = id;

    if (result.success) {
        JSONValue r;
        r["success"] = true;
        r["output"] = result.output;
        r["wasmSize"] = cast(long)result.wasmSize;
        r["cacheHits"] = cast(long)result.cacheHits;
        r["cacheMisses"] = cast(long)result.cacheMisses;
        r["timeMs"] = result.timeMs;
        json["result"] = r;
    } else {
        JSONValue e;
        e["code"] = "COMPILE_ERROR";
        e["message"] = result.error;
        json["error"] = e;
    }

    return json.toString() ~ "\n";
}

/// Serialize a status response
string serializeStatusResponse(int id, StatusResult result) {
    JSONValue json;
    json["id"] = id;

    JSONValue r;
    r["cachedFunctions"] = cast(long)result.cachedFunctions;
    r["depGraphLoaded"] = result.depGraphLoaded;
    r["compilations"] = cast(long)result.compilations;
    json["result"] = r;

    return json.toString() ~ "\n";
}

/// Serialize an error response
string serializeError(int id, string code, string message) {
    JSONValue json;
    json["id"] = id;

    JSONValue e;
    e["code"] = code;
    e["message"] = message;
    json["error"] = e;

    return json.toString() ~ "\n";
}

/// Serialize a simple ack response
string serializeAck(int id) {
    JSONValue json;
    json["id"] = id;

    JSONValue r;
    r["ok"] = true;
    json["result"] = r;

    return json.toString() ~ "\n";
}
