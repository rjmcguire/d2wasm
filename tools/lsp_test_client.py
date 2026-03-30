#!/usr/bin/env python3
"""
LSP Test Client for d2wasm

Interactive CLI client that speaks JSON-RPC 2.0 to the d2wasm LSP server.
Shows all traffic for debugging.

Usage:
    # Interactive mode — opens a file, then you type commands
    ./tools/lsp_test_client.py ./d2wasm tests/milestones/milestone_250_lsp_diagnostics/test.d

    # One-shot: run specific commands then exit
    ./tools/lsp_test_client.py ./d2wasm myfile.d --commands "hover 1 5" "completion 3 10" "definition 2 8"

    # Just check initialize + diagnostics on open
    ./tools/lsp_test_client.py ./d2wasm myfile.d --commands "diagnostics"

Commands (in interactive mode, type these at the prompt):
    hover LINE COL          — textDocument/hover at 0-based line:col
    definition LINE COL     — textDocument/definition
    completion LINE COL     — textDocument/completion
    references LINE COL     — textDocument/references
    symbols                 — textDocument/documentSymbol
    signature LINE COL      — textDocument/signatureHelp
    semantictokens          — textDocument/semanticTokens/full
    codelens                — textDocument/codeLens
    diagnostics             — show last received diagnostics
    raw JSON                — send raw JSON-RPC body
    quit / q                — shutdown and exit
"""

import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path


class LSPClient:
    def __init__(self, server_cmd, verbose=True):
        self.verbose = verbose
        self.next_id = 1
        self.pending = {}           # id → threading.Event
        self.responses = {}         # id → response JSON
        self.notifications = []     # collected notifications
        self.diagnostics = {}       # uri → diagnostics list
        self.stderr_lines = []

        self.proc = subprocess.Popen(
            server_cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        # Reader threads
        self._reader = threading.Thread(target=self._read_stdout, daemon=True)
        self._reader.start()
        self._err_reader = threading.Thread(target=self._read_stderr, daemon=True)
        self._err_reader.start()

    # ── Wire protocol ──

    def _send(self, body):
        raw = json.dumps(body)
        header = f"Content-Length: {len(raw)}\r\n\r\n"
        if self.verbose:
            method = body.get("method", "(response)")
            _id = body.get("id", "-")
            print(f"\033[36m  → {method}  id={_id}\033[0m")
            print(f"\033[90m    {_compact(body)}\033[0m")
        self.proc.stdin.write(header.encode())
        self.proc.stdin.write(raw.encode())
        self.proc.stdin.flush()

    def _read_stdout(self):
        """Read JSON-RPC messages from server stdout."""
        buf = b""
        while True:
            chunk = self.proc.stdout.read(1)
            if not chunk:
                break
            buf += chunk

            # Try to find Content-Length header + body
            while b"\r\n\r\n" in buf:
                header_end = buf.index(b"\r\n\r\n")
                header_part = buf[:header_end].decode("utf-8", errors="replace")
                content_length = None
                for line in header_part.split("\r\n"):
                    if line.lower().startswith("content-length:"):
                        content_length = int(line.split(":")[1].strip())
                        break

                if content_length is None:
                    # Not a valid header — possibly stdout garbage
                    garbage = buf[:header_end + 4]
                    buf = buf[header_end + 4:]
                    print(f"\033[31m  !! STDOUT GARBAGE (no Content-Length): {garbage!r}\033[0m")
                    continue

                body_start = header_end + 4
                body_end = body_start + content_length
                if len(buf) < body_end:
                    break  # need more data

                body_bytes = buf[body_start:body_end]
                buf = buf[body_end:]

                try:
                    msg = json.loads(body_bytes)
                except json.JSONDecodeError as e:
                    print(f"\033[31m  !! JSON parse error: {e}\033[0m")
                    print(f"\033[31m     Raw: {body_bytes!r}\033[0m")
                    continue

                self._handle_message(msg)

            # Detect non-Content-Length stdout garbage (e.g., bare writeln output)
            # If buffer is large but has no header pattern, it's garbage
            if len(buf) > 4096 and b"Content-Length" not in buf:
                print(f"\033[31m  !! STDOUT GARBAGE (large buffer, no header): {buf[:200]!r}...\033[0m")
                buf = b""

    def _handle_message(self, msg):
        if self.verbose:
            if "method" in msg:
                print(f"\033[33m  ← {msg['method']}\033[0m")
            elif "id" in msg:
                print(f"\033[32m  ← response id={msg['id']}\033[0m")
            print(f"\033[90m    {_compact(msg)}\033[0m")

        # Notification
        if "method" in msg and "id" not in msg:
            self.notifications.append(msg)
            if msg["method"] == "textDocument/publishDiagnostics":
                params = msg.get("params", {})
                self.diagnostics[params.get("uri", "")] = params.get("diagnostics", [])
            return

        # Response to a request
        msg_id = msg.get("id")
        if msg_id is not None:
            self.responses[msg_id] = msg
            evt = self.pending.pop(msg_id, None)
            if evt:
                evt.set()

    def _read_stderr(self):
        """Read server stderr and print it."""
        for line in self.proc.stderr:
            text = line.decode("utf-8", errors="replace").rstrip()
            self.stderr_lines.append(text)
            if self.verbose:
                print(f"\033[35m  [stderr] {text}\033[0m")

    # ── Request helpers ──

    def request(self, method, params, timeout=10):
        req_id = self.next_id
        self.next_id += 1
        evt = threading.Event()
        self.pending[req_id] = evt
        self._send({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params})
        if evt.wait(timeout):
            return self.responses.pop(req_id, None)
        else:
            print(f"\033[31m  !! TIMEOUT waiting for response to {method} (id={req_id})\033[0m")
            self.pending.pop(req_id, None)
            return None

    def notify(self, method, params):
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    # ── LSP lifecycle ──

    def initialize(self, root_uri=None):
        params = {
            "processId": os.getpid(),
            "capabilities": {},
            "rootUri": root_uri,
        }
        if root_uri:
            params["workspaceFolders"] = [{"uri": root_uri, "name": "workspace"}]
        resp = self.request("initialize", params)
        self.notify("initialized", {})
        return resp

    def open_file(self, file_path):
        uri = Path(file_path).resolve().as_uri()
        text = Path(file_path).read_text()
        self.notify("textDocument/didOpen", {
            "textDocument": {
                "uri": uri,
                "languageId": "d",
                "version": 1,
                "text": text,
            }
        })
        # Give server time to compile and publish diagnostics
        time.sleep(1.5)
        return uri

    def hover(self, uri, line, col):
        return self.request("textDocument/hover", {
            "textDocument": {"uri": uri},
            "position": {"line": line, "character": col},
        })

    def definition(self, uri, line, col):
        return self.request("textDocument/definition", {
            "textDocument": {"uri": uri},
            "position": {"line": line, "character": col},
        })

    def completion(self, uri, line, col):
        return self.request("textDocument/completion", {
            "textDocument": {"uri": uri},
            "position": {"line": line, "character": col},
        })

    def references(self, uri, line, col):
        return self.request("textDocument/references", {
            "textDocument": {"uri": uri},
            "position": {"line": line, "character": col},
            "context": {"includeDeclaration": True},
        })

    def document_symbols(self, uri):
        return self.request("textDocument/documentSymbol", {
            "textDocument": {"uri": uri},
        })

    def signature_help(self, uri, line, col):
        return self.request("textDocument/signatureHelp", {
            "textDocument": {"uri": uri},
            "position": {"line": line, "character": col},
        })

    def semantic_tokens(self, uri):
        return self.request("textDocument/semanticTokens/full", {
            "textDocument": {"uri": uri},
        })

    def code_lens(self, uri):
        return self.request("textDocument/codeLens", {
            "textDocument": {"uri": uri},
        })

    def shutdown(self):
        resp = self.request("shutdown", None, timeout=5)
        self.notify("exit", None)
        try:
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        return resp


def _compact(obj, max_len=200):
    """Compact JSON for display."""
    s = json.dumps(obj, separators=(",", ":"))
    if len(s) > max_len:
        return s[:max_len] + "..."
    return s


def pretty(obj):
    """Pretty-print JSON result."""
    if obj is None:
        print("  (null/timeout)")
        return
    if "error" in obj:
        err = obj["error"]
        print(f"  \033[31mERROR {err.get('code')}: {err.get('message')}\033[0m")
        return
    result = obj.get("result")
    if result is None:
        print("  (result: null)")
    else:
        print(json.dumps(result, indent=2))


def print_diagnostics(client, uri):
    diags = client.diagnostics.get(uri, [])
    if not diags:
        print("  No diagnostics.")
        return
    for d in diags:
        sev = {1: "ERROR", 2: "WARN", 3: "INFO", 4: "HINT"}.get(d.get("severity", 0), "?")
        r = d.get("range", {})
        start = r.get("start", {})
        print(f"  [{sev}] L{start.get('line', '?')}:{start.get('character', '?')} — {d.get('message', '')}")


def run_command(client, uri, cmd_str):
    parts = cmd_str.strip().split()
    if not parts:
        return True
    cmd = parts[0].lower()

    if cmd in ("quit", "q", "exit"):
        return False
    elif cmd == "hover" and len(parts) == 3:
        pretty(client.hover(uri, int(parts[1]), int(parts[2])))
    elif cmd == "definition" and len(parts) == 3:
        pretty(client.definition(uri, int(parts[1]), int(parts[2])))
    elif cmd == "completion" and len(parts) == 3:
        pretty(client.completion(uri, int(parts[1]), int(parts[2])))
    elif cmd == "references" and len(parts) == 3:
        pretty(client.references(uri, int(parts[1]), int(parts[2])))
    elif cmd == "symbols":
        pretty(client.document_symbols(uri))
    elif cmd == "signature" and len(parts) == 3:
        pretty(client.signature_help(uri, int(parts[1]), int(parts[2])))
    elif cmd == "semantictokens":
        pretty(client.semantic_tokens(uri))
    elif cmd == "codelens":
        pretty(client.code_lens(uri))
    elif cmd == "diagnostics":
        print_diagnostics(client, uri)
    elif cmd == "raw":
        body = json.loads(" ".join(parts[1:]))
        if "id" in body:
            pretty(client.request(body["method"], body.get("params", {})))
        else:
            client.notify(body["method"], body.get("params", {}))
    elif cmd == "stderr":
        for line in client.stderr_lines[-20:]:
            print(f"  {line}")
    elif cmd == "help":
        print(__doc__)
    else:
        print(f"  Unknown command: {cmd_str}")
        print("  Commands: hover L C | definition L C | completion L C | references L C")
        print("            symbols | signature L C | semantictokens | codelens | diagnostics")
        print("            stderr | raw JSON | quit")
    return True


def main():
    import argparse
    parser = argparse.ArgumentParser(description="LSP test client for d2wasm")
    parser.add_argument("server", help="Path to d2wasm binary")
    parser.add_argument("file", help="D source file to open")
    parser.add_argument("--commands", nargs="*", help="Commands to run (non-interactive)")
    parser.add_argument("--quiet", action="store_true", help="Suppress traffic logging")
    parser.add_argument("--extra-args", nargs="*", default=[], help="Extra args for server")
    args = parser.parse_args()

    server_path = str(Path(args.server).resolve())
    file_path = str(Path(args.file).resolve())
    root_dir = str(Path(file_path).parent)

    print(f"Server: {server_path}")
    print(f"File:   {file_path}")
    print(f"Root:   {root_dir}")
    print()

    client = LSPClient(
        [server_path, "--lsp"] + args.extra_args,
        verbose=not args.quiet,
    )

    # Initialize
    print("=== Initialize ===")
    resp = client.initialize(root_uri=f"file://{root_dir}")
    if resp and "result" in resp:
        caps = resp["result"].get("capabilities", {})
        print(f"  Server capabilities: {', '.join(k for k, v in caps.items() if v)}")
    else:
        print(f"  \033[31mInitialize failed!\033[0m")
        pretty(resp)
        client.shutdown()
        sys.exit(1)

    # Open file
    print(f"\n=== Open {Path(file_path).name} ===")
    uri = client.open_file(file_path)

    # Show diagnostics
    print(f"\n=== Diagnostics ===")
    print_diagnostics(client, uri)

    if args.commands:
        # Non-interactive: run commands then exit
        for cmd in args.commands:
            if cmd == "diagnostics":
                continue  # already shown
            print(f"\n=== {cmd} ===")
            run_command(client, uri, cmd)
    else:
        # Interactive mode
        print(f"\nType commands (hover L C, definition L C, completion L C, etc.) or 'quit'")
        print(f"Lines/columns are 0-based. Type 'help' for all commands.\n")
        try:
            while True:
                try:
                    cmd = input("\033[1mlsp>\033[0m ")
                except EOFError:
                    break
                if not run_command(client, uri, cmd):
                    break
        except KeyboardInterrupt:
            pass

    print("\n=== Shutdown ===")
    client.shutdown()
    print("Done.")


if __name__ == "__main__":
    main()
