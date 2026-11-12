#!/bin/sh
# Build tree-sitter language static libraries used by d2wasm.
# Safe to re-run; skips work when outputs are already newer than sources.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

is_windows() {
    if [ "${OS:-}" = "Windows_NT" ]; then
        return 0
    fi
    case "$(uname -s 2>/dev/null || true)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
    esac
    return 1
}

if is_windows; then
    CC="${CC:-clang}"
    OBJEXT=obj
    LIBEXT=lib
    PICFLAGS=""
    EXTRA_CFLAGS="-D_CRT_SECURE_NO_WARNINGS"
    pack_static() {
        dest="$1"
        shift
        llvm-lib "-out:$dest" "$@"
    }
else
    CC="${CC:-cc}"
    OBJEXT=o
    LIBEXT=a
    PICFLAGS="-fPIC"
    EXTRA_CFLAGS=""
    pack_static() {
        dest="$1"
        shift
        ar rcs "$dest" "$@"
    }
fi

TS_VER="0.25.10"
TS_DIR="thirdparty/tree-sitter"
TS_LIB="$TS_DIR/libtree-sitter.$LIBEXT"
if [ ! -f "$TS_LIB" ]; then
    echo "Building $TS_LIB"
    mkdir -p thirdparty
    if [ ! -f "$TS_DIR/Makefile" ]; then
        curl -fsSL -o /tmp/tree-sitter.tar.gz \
            "https://github.com/tree-sitter/tree-sitter/archive/refs/tags/v${TS_VER}.tar.gz"
        tar xzf /tmp/tree-sitter.tar.gz -C /tmp
        rm -rf "$TS_DIR"
        mv "/tmp/tree-sitter-${TS_VER}" "$TS_DIR"
        rm -f /tmp/tree-sitter.tar.gz
    fi
    if is_windows; then
        ts_obj="$TS_DIR/libtree-sitter.$OBJEXT"
        $CC -c -O2 -std=c11 $EXTRA_CFLAGS \
            -I "$TS_DIR/lib/include" -I "$TS_DIR/lib/src" \
            -o "$ts_obj" "$TS_DIR/lib/src/lib.c"
        pack_static "$TS_LIB" "$ts_obj"
        rm -f "$ts_obj"
    else
        make -C "$TS_DIR" -j"$(nproc 2>/dev/null || echo 4)"
    fi
fi

build_grammar() {
    name="$1"
    dir="grammar/tree-sitter-$name"
    out="$dir/libtree-sitter-$name.$LIBEXT"

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
        obj="${f%.*}.$OBJEXT"
        $CC -c -O2 $PICFLAGS $EXTRA_CFLAGS -I "$dir/src" "$f" -o "$obj"
        objs="$objs $obj"
    done
    pack_static "$out" $objs
    rm -f $objs
}

build_grammar d
build_grammar c
build_grammar javascript
