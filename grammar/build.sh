#!/bin/sh
# Build tree-sitter language static libraries used by d2wasm.
# Safe to re-run; skips work when outputs are already newer than sources.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TS_VER="0.25.10"
TS_DIR="thirdparty/tree-sitter"
if [ ! -f "$TS_DIR/libtree-sitter.a" ]; then
    echo "Building $TS_DIR/libtree-sitter.a"
    mkdir -p thirdparty
    if [ ! -f "$TS_DIR/Makefile" ]; then
        curl -fsSL -o /tmp/tree-sitter.tar.gz \
            "https://github.com/tree-sitter/tree-sitter/archive/refs/tags/v${TS_VER}.tar.gz"
        tar xzf /tmp/tree-sitter.tar.gz -C /tmp
        rm -rf "$TS_DIR"
        mv "/tmp/tree-sitter-${TS_VER}" "$TS_DIR"
        rm -f /tmp/tree-sitter.tar.gz
    fi
    make -C "$TS_DIR" -j"$(nproc 2>/dev/null || echo 4)"
fi

build_grammar() {
    name="$1"
    dir="grammar/tree-sitter-$name"
    out="$dir/libtree-sitter-$name.a"

    if [ ! -d "$dir" ]; then
        echo "error: missing $dir (run: git submodule update --init --recursive)" >&2
        exit 1
    fi

    srcs=""
    for f in "$dir/src/parser.c" "$dir/src/scanner.c" "$dir/src/scanner.cc"; do
        if [ -f "$f" ]; then
            srcs="$srcs $f"
        fi
    done
    if [ -z "$srcs" ]; then
        echo "error: no parser/scanner sources in $dir/src" >&2
        exit 1
    fi

    need_rebuild=0
    if [ ! -f "$out" ]; then
        need_rebuild=1
    else
        for f in $srcs; do
            if [ "$f" -nt "$out" ]; then
                need_rebuild=1
                break
            fi
        done
    fi
    [ "$need_rebuild" -eq 0 ] && return 0

    echo "Building $out"
    objs=""
    for f in $srcs; do
        obj="${f%.*}.o"
        cc -c -O2 -fPIC -I "$dir/src" "$f" -o "$obj"
        objs="$objs $obj"
    done
    ar rcs "$out" $objs
    rm -f $objs
}

build_grammar d
build_grammar c
build_grammar javascript
