#!/bin/bash
# Print the executable this shell can run.
# $1 is the directory, $2 is the name without .exe.
# Git Bash (MINGW, MSYS, Cygwin) runs name.exe.
# Linux and macOS run name, including when a Windows .exe sits beside it.
host_exe() {
    local dir="$1"
    local name="$2"
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            printf '%s\n' "$dir/$name.exe"
            ;;
        *)
            printf '%s\n' "$dir/$name"
            ;;
    esac
}

d2wasm_bin() {
    host_exe "$1" d2wasm
}

# Directory both this shell and a native Windows program can open.
# Git Bash mktemp returns /tmp/..., which Windows Python and d2wasm.exe
# do not see. cygpath -m keeps forward slashes so the path is safe in JSON.
# Linux and macOS paths are unchanged.
native_workdir() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            cygpath -m "$1"
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}
