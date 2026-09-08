#!/bin/sh
# performance comparison (linux/macOS counterpart of tools/benchmark.ps1):
# baseline (git ref, -O2, collision detection always on) vs current (-O3
# -flto, collision detection on/off, optional PGO), compiled to wasm and run
# under node.  needs the emsdk environment sourced (`source .../emsdk_env.sh`)
# so emcc and node are on PATH.
#
# usage: tools/benchmark.sh [options]
#   -p, --puzzle <file>    puzzle to simulate
#   -s, --solution <file>  solution to simulate
#   -c, --cycles <n>       cycle target per repeat
#   -r, --repeats <n>      repeats per build (best of n is reported)
#   -b, --base <ref>       baseline git ref (default master)
#   --pgo                  measure the current build with the shipped PGO
#                          profile (build/pgo-wasm.profdata)
#   --train                retrain build/pgo-wasm.profdata from the test/
#                          corpus first (then measure, if --pgo)
#
# LLVMPROFDATA (default llvm-profdata) must match the emsdk clang major
# version; only needed with --train.
set -e
source /usr/bin/emsdk_env.sh

Puzzle="./test/puzzle/weeklies-2026/weeklies2026_fismmecyhmptu.puzzle"
Solution="./test/solution/weeklies-2026/Week 8/bb.solution"
Cycles=10000
Repeats=3
Base="master"
PGO=0
Train=0
ProfileRt="build/libclang_rt.profile-emscripten.a"

while [ $# -gt 0 ]; do
    case "$1" in
    -p | --puzzle) Puzzle="$2"; shift 2 ;;
    -s | --solution) Solution="$2"; shift 2 ;;
    -c | --cycles) Cycles="$2"; shift 2 ;;
    -r | --repeats) Repeats="$2"; shift 2 ;;
    -b | --base) Base="$2"; shift 2 ;;
    --pgo) PGO=1; shift ;;
    --train) Train=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
LLVMPROFDATA=${LLVMPROFDATA:-llvm-profdata}
srcs="collision.c decode.c parse.c sim.c steady-state.c verifier.c"
profdata="build/pgo-wasm.profdata"

if [ "$Train" -eq 1 ]; then
    if [ ! -f "$ProfileRt" ]; then
        make "$ProfileRt"
    fi
    echo "training on test/ corpus (instrumented build)..."
    emcc -O2 -DNDEBUG -fprofile-instr-generate=build/train.profraw -sEXIT_RUNTIME=1 \
        -s ALLOW_MEMORY_GROWTH=1 -std=c11 -w -D_DEFAULT_SOURCE -I. \
        $srcs tools/train.c "$ProfileRt" -o build/train.js -sNODERAWFS=1
    node build/train.js
    "$LLVMPROFDATA" merge -output="$profdata" build/train.profraw
    echo "PGO profile written to $profdata"
    rm -f build/train.profraw
    if [ "$PGO" -ne 1 ]; then
        exit 0
    fi
fi

# current: same codegen flags as the shipped build/libverify.wasm
# (-gseparate-dwarf keeps binaryen's slower postlink passes out)
current_flags="-O3 -flto -gseparate-dwarf -DNDEBUG"
pgolabel=""
if [ "$PGO" -eq 1 ]; then
    if [ ! -f "$profdata" ]; then
        echo "$profdata missing; run with --train first" >&2
        exit 1
    fi
    current_flags="$current_flags -fprofile-instr-use=$profdata"
    pgolabel=" + PGO"
fi

echo "building current (extension, -O3 -flto$pgolabel)..."
# shellcheck disable=SC2086
emcc $current_flags -std=c11 -w -D_DEFAULT_SOURCE -I. \
    $srcs tools/bench.c -o build/bench-current.js -sNODERAWFS=1

sha=$(git rev-parse --short "$Base^{commit}")
cache="build/bench-cache/$sha"
if [ ! -f "$cache/sim.c" ]; then
    echo "extracting baseline sources ($Base @ $sha)..."
    mkdir -p "$cache"
    for f in $srcs collision.h decode.h parse.h sim.h steady-state.h verifier.h; do
        git show "$Base:$f" > "$cache/$f"
    done
fi
echo "building baseline ($sha, -O2, collision detection always on)..."
# compile the cached baseline sources (not the working tree!) against the
# cached baseline headers
base_srcs=""
for s in $srcs; do
    base_srcs="$base_srcs $cache/$s"
done
# shellcheck disable=SC2086
emcc -O2 -DNDEBUG -std=c11 -w -D_DEFAULT_SOURCE -DNO_COLL_API -I"$cache" \
    $base_srcs tools/bench.c -o build/bench-base.js -sNODERAWFS=1

echo "== baseline ($sha, -O2, collision detection always on) =="
node build/bench-base.js "$Puzzle" "$Solution" "$Cycles" "$Repeats"
echo "== current (collision detection on$pgolabel) =="
node build/bench-current.js "$Puzzle" "$Solution" "$Cycles" "$Repeats" 0
echo "== current (collision detection OFF$pgolabel) =="
node build/bench-current.js "$Puzzle" "$Solution" "$Cycles" "$Repeats" 1
