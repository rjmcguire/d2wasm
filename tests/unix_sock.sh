#!/bin/bash
# Compile-server helpers shared by milestone and parity scripts.
#
# Linux and macOS: a Unix socket shows up as a socket inode, and nc -U
# speaks the NDJSON protocol.
# Git Bash: Winsock AF_UNIX files stat as regular files, and nc is often
# absent. Readiness is the server's pid file. Requests go through
# tests/unix_ndjson, built on first use.

_unix_sock_dir() {
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

# native_workdir lives in d2wasm_bin.sh. Load it when this file is sourced alone.
if ! declare -F native_workdir >/dev/null 2>&1; then
    source "$(_unix_sock_dir)/d2wasm_bin.sh"
fi

server_ready() {
    local sock="$1"
    local pidfile="${sock%.*}.pid"
    [ -S "$sock" ] || [ -s "$pidfile" ]
}

unix_ndjson_bin() {
    local dir src out cc libs
    dir="$(_unix_sock_dir)"
    src="$dir/unix_ndjson.c"
    libs=""
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            out="$dir/unix_ndjson.exe"
            cc="${CC:-clang}"
            libs="-lws2_32"
            ;;
        *)
            out="$dir/unix_ndjson"
            cc="${CC:-cc}"
            ;;
    esac
    if [ ! -x "$out" ] || [ "$src" -nt "$out" ]; then
        if [ -n "$libs" ]; then
            "$cc" -O2 -o "$out" "$src" $libs </dev/null >&2 || return 1
        else
            "$cc" -O2 -o "$out" "$src" </dev/null >&2 || return 1
        fi
    fi
    printf '%s\n' "$out"
}

# Read one request from stdin. Write one response to stdout.
unix_request() {
    local sock="$1"
    if [ -S "$sock" ] && command -v nc >/dev/null 2>&1; then
        nc -N -U "$sock"
        return
    fi
    local bin
    bin="$(unix_ndjson_bin)" || return 1
    "$bin" "$sock"
}
