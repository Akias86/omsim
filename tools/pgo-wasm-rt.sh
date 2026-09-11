#!/bin/sh
# Build the wasm profile runtime archive (libclang_rt.profile-emscripten.a) that
# emsdk does not ship, from the matching LLVM compiler-rt sources.
#
# Usage:  ./tools/pgo-wasm-rt.sh   (emcc + git on PATH; network required once)
#
# The archive is written to build/libclang_rt.profile-emscripten.a; the wasm
# PGO flow (benchmark.ps1 -Train / benchmark.sh --train, or the manual
# recipe in the Makefile comments) links it into instrumented builds.
#
# Pin to the same LLVM sources as the emsdk clang: read the revision from
# `clang --version` so the runtime matches the instrumenting compiler (a
# raw-profile format mismatch crashes at profile write and the profraw will
# not merge).  Falls back to a known tag if detection fails.
set -e
TAG=llvmorg-21.1.0
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD="$ROOT/build"
WORK="$BUILD/pgo-rt-src"
OUT="$BUILD/libclang_rt.profile-emscripten.a"

if ! command -v emcc >/dev/null 2>&1; then
    echo "error: emcc not found on PATH (activate emsdk first)" >&2
    exit 1
fi

CLANG="$(dirname "$(command -v emcc)")/../bin/clang"
[ -x "$CLANG" ] || CLANG=$(command -v clang || true)
REV=""
if [ -n "$CLANG" ] && [ -x "$CLANG" ]; then
    REV=$("$CLANG" --version | sed -nE 's/.*llvm-project +([0-9a-f]{40}).*/\1/p' | head -n 1)
fi
if [ -n "$REV" ]; then
    PIN=$REV
else
    echo "could not detect the emsdk clang revision, falling back to $TAG" >&2
    PIN=$TAG
fi

mkdir -p "$BUILD"
if [ ! -f "$BUILD/.pgo-rt-cloned-$PIN" ]; then
    rm -rf "$WORK"
    git clone --depth 1 --filter=blob:none --sparse \
        https://github.com/llvm/llvm-project "$WORK"
    git -C "$WORK" sparse-checkout set compiler-rt cmake
    if [ -n "$REV" ]; then
        git -C "$WORK" fetch --depth 1 origin "$REV"
    else
        git -C "$WORK" fetch --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG"
    fi
    git -C "$WORK" checkout --detach "$PIN"
    touch "$BUILD/.pgo-rt-cloned-$PIN"
fi

P="$WORK/compiler-rt/lib/profile"
INC="$WORK/compiler-rt/include"
OBJDIR="$BUILD/pgo-rt-obj"
rm -rf "$OBJDIR"
mkdir -p "$OBJDIR"

# profile runtime C sources; PlatformLinux supports wasm (wasm-ld provides
# the __start_/__stop_ section symbols).  PlatformOther compiles empty on wasm.
for f in InstrProfiling.c InstrProfilingBuffer.c InstrProfilingFile.c \
         InstrProfilingInternal.c InstrProfilingMerge.c InstrProfilingMergeFile.c \
         InstrProfilingNameVar.c InstrProfilingPlatformLinux.c \
         InstrProfilingValue.c InstrProfilingVersionVar.c \
         InstrProfilingWriter.c InstrProfilingUtil.c; do
    emcc -O2 -std=c11 -D_GNU_SOURCE -w -I"$P" -I"$INC" -c "$P/$f" -o "$OBJDIR/$f.o"
done
emcc -O2 -std=c++17 -fno-rtti -fno-exceptions -w -I"$P" -I"$INC" \
    -c "$P/InstrProfilingRuntime.cpp" -o "$OBJDIR/InstrProfilingRuntime.cpp.o"
# wasm has no uname: provide the hostname stub that POSIX builds get from it.
printf '%s\n' 'int lprofGetHostName(char *Name, int Len) { (void)Name; (void)Len; return -1; }' \
    > "$OBJDIR/wasm_stub.c"
emcc -O2 -std=c11 -w -c "$OBJDIR/wasm_stub.c" -o "$OBJDIR/wasm_stub.o"

emar rcs "$OUT" "$OBJDIR"/*.o
rm -rf "$OBJDIR"
echo "wrote $OUT"
