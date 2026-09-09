# Build the wasm profile runtime archive (libclang_rt.profile-emscripten.a) that
# emsdk does not ship, from the matching LLVM compiler-rt sources.
# Windows port of tools/pgo-wasm-rt.sh (make pgo-wasm uses the .ps1 on Windows,
# the .sh elsewhere).
#
# Needs: emcc + git on PATH (activate emsdk first); network required once.
$ErrorActionPreference = "Stop"
$TAG = "llvmorg-21.1.0"
$ROOT = Split-Path $PSScriptRoot -Parent
$BUILD = Join-Path $ROOT "build"
$WORK = Join-Path $BUILD "pgo-rt-src"
$OUT = Join-Path $BUILD "libclang_rt.profile-emscripten.a"

if (-not (Get-Command emcc -ErrorAction SilentlyContinue)) {
    Write-Host "error: emcc not found on PATH (activate emsdk first)" -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Force -Path $BUILD | Out-Null
$stamp = Join-Path $BUILD ".pgo-rt-cloned-$TAG"
if (-not (Test-Path $stamp)) {
    if (Test-Path $WORK) { Remove-Item -Recurse -Force $WORK }
    git clone --depth 1 --filter=blob:none --sparse --branch $TAG https://github.com/llvm/llvm-project $WORK
    if ($LASTEXITCODE) { throw "git clone failed" }
    git -C $WORK sparse-checkout set compiler-rt cmake
    if ($LASTEXITCODE) { throw "git sparse-checkout failed" }
    New-Item -ItemType File -Force -Path $stamp | Out-Null
}

$P = Join-Path $WORK "compiler-rt\lib\profile"
$INC = Join-Path $WORK "compiler-rt\include"
$OBJDIR = Join-Path $BUILD "pgo-rt-obj"
if (Test-Path $OBJDIR) { Remove-Item -Recurse -Force $OBJDIR }
New-Item -ItemType Directory -Force -Path $OBJDIR | Out-Null

# profile runtime C sources; PlatformLinux supports wasm (wasm-ld provides the
# __start_/__stop_ section symbols).  PlatformOther compiles empty on wasm.
$cfiles = @(
    "InstrProfiling.c", "InstrProfilingBuffer.c", "InstrProfilingFile.c",
    "InstrProfilingInternal.c", "InstrProfilingMerge.c", "InstrProfilingMergeFile.c",
    "InstrProfilingNameVar.c", "InstrProfilingPlatformLinux.c",
    "InstrProfilingValue.c", "InstrProfilingVersionVar.c",
    "InstrProfilingWriter.c", "InstrProfilingUtil.c"
)
foreach ($f in $cfiles) {
    & emcc -O2 -std=c11 -D_GNU_SOURCE -w "-I$P" "-I$INC" -c (Join-Path $P $f) -o (Join-Path $OBJDIR "$f.o")
    if ($LASTEXITCODE) { throw "emcc compile failed: $f" }
}
& emcc -O2 -std=c++17 -fno-rtti -fno-exceptions -w "-I$P" "-I$INC" -c (Join-Path $P "InstrProfilingRuntime.cpp") -o (Join-Path $OBJDIR "InstrProfilingRuntime.cpp.o")
if ($LASTEXITCODE) { throw "emcc compile failed: InstrProfilingRuntime.cpp" }
# wasm has no uname: provide the hostname stub that POSIX builds get from it.
$stub = Join-Path $OBJDIR "wasm_stub.c"
[System.IO.File]::WriteAllText($stub, "int lprofGetHostName(char *Name, int Len) { (void)Name; (void)Len; return -1; }`n")
& emcc -O2 -std=c11 -w -c $stub -o (Join-Path $OBJDIR "wasm_stub.o")
if ($LASTEXITCODE) { throw "emcc compile failed: wasm_stub.c" }

$objs = Get-ChildItem $OBJDIR -Filter *.o | ForEach-Object { $_.FullName }
& emar rcs $OUT $objs
if ($LASTEXITCODE) { throw "emar failed" }
Remove-Item -Recurse -Force $OBJDIR
Write-Host "wrote $OUT"
