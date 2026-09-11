# omsim

A C simulator for Opus Magnum `.solution` / `.puzzle` files, with an FFI-oriented
verifier API for bots and tooling.

## Build

All artifacts go to `build/` (`build/libverify.so`, `build/omsim.exe` on
Windows, ...).  Requires a C11 compiler (clang/gcc); the wasm build needs
emscripten.

```sh
make omsim                       # CLI: simulate a puzzle/solution pair
make libverify.so                # shared library for FFI, PGO by default
make libverify.dll               # Windows DLL, PGO by default
make libverify.wasm              # Emscripten build, PGO by default
make run-tests                   # validate test/ corpus against recorded metrics
make llvm-fuzz                   # libFuzzer harness for decode robustness
```

Usage:

```sh
./build/omsim -p <puzzle.puzzle> -f <solution.solution>   # or pass paths directly
```

`-march=native` is on by default; override with `make NATIVE=`.

## Verifier API

`libverify.*` exposes the API documented in `verifier.h` (create by file or
bytes, evaluate metrics, inspect errors/output intervals, ...). Key extensions:

- `verifier_set_collision_detection(v, 0|1)` — disable the motion-phase
  collision sweep at runtime. Much faster; only valid for solutions that do not
  collide (results may diverge otherwise).
- `verifier_advance(v, n)` / `verifier_current_cycle` / `verifier_completed` /
  `verifier_converged` / `verifier_measure_current` — incremental, resumable
  simulation for interactive UIs.

## PGO

`libverify.so` / `libverify.dll` / `libverify.wasm` are PGO-optimized by
default (clang-only; gcc uses different flags).  Building one first trains a
profile by running the test/ corpus through an instrumented trainer
(`tools/train.c` — natively, or as wasm under node for the wasm build),
merges it with llvm-profdata, then links with `-fprofile-instr-use`.
Everything is dependency-tracked, so from a clean tree a single
`make libverify.so` / `make libverify.wasm` does the whole pipeline, and
retraining happens automatically whenever the sources or the corpus change
(unix; on Windows the corpus is not tracked — delete `build/pgo.profdata` /
`build/pgo-wasm.profdata` to force a retrain).

```sh
make libverify.so                 # native: train on test/ corpus, build PGO .so  (= make pgo)
make libverify.wasm               # wasm: train under node, build PGO wasm       (= make pgo-wasm)
make libverify.so PGO=0           # plain -O3 build, no profiling
```

`LLVMPROFDATA` is auto-detected (`llvm-profdata` / `xcrun -f llvm-profdata`),
but the detected tool must match the compiler that wrote the profile: emsdk
4.x uses clang 21, which writes raw profile format v10 — an older
`llvm-profdata` (e.g. an LLVM 18 install) cannot merge it.  If merging fails
with "raw profile version mismatch", point `LLVMPROFDATA` at a tool with the
same major version as your compiler:

```sh
make libverify.wasm LLVMPROFDATA=/path/to/llvm-profdata   # any LLVM >= 21
```

`make libverify.wasm` needs the emsdk environment sourced
(`source .../emsdk_env.sh` / `emsdk_env.bat`) so emcc and node are on PATH;
on first use it builds the profile runtime archive emsdk does not ship
(tools/pgo-wasm-rt.sh, needs git + network once).

## Benchmark

`tools/benchmark.ps1` (Windows) / `tools/benchmark.sh` (unix, needs the emsdk
environment) compare baseline vs current, with optional `-PGO -Train` /
`--pgo --train` (retrain from the test/ corpus and measure the PGO build).

## Known issues

- "Spooky action at a distance" via conduit cloning is not implemented.
- Track reset differs from the game in certain situations (see
  `test/not-working-yet/overlapping-track-reset`).
