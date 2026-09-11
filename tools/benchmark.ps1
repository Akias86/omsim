param(
    [string]$Puzzle = "tmp\P020.puzzle",
    [string]$Solution = "tmp\armor-filament-6.solution",
    [long]$Cycles = 50000,
    [int]$Repeats = 3,
    [string]$Base = "master",
    # measure the current build with the shipped PGO profile (build/pgo-wasm.profdata)
    [switch]$PGO,
    # retrain build/pgo-wasm.profdata from the test/ corpus, then (if -PGO) measure
    [switch]$Train,
    # llvm-profdata matching the emsdk clang (use LLVM 21+ for emsdk 4.x)
    [string]$ProfdataExe = "",
    # wasm profile runtime archive (emsdk does not ship it; see Makefile notes)
    [string]$ProfileRt = "build/libclang_rt.profile-emscripten.a"
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    # invoke emcc through cmd: powershell 5.1 mangles `-fprofile-*=path` style
    # arguments when calling the emcc batch wrapper directly
    function Invoke-Emcc([string]$argstr, [string]$what) {
        cmd /c "emcc $argstr"
        if ($LASTEXITCODE) { throw "emcc $what failed" }
    }
    $srcs = "collision.c decode.c parse.c sim.c steady-state.c verifier.c"

    if ($Train) {
        if (-not (Test-Path $ProfileRt)) { throw "profile runtime not found: $ProfileRt" }
        if ($ProfdataExe -eq "" -and $env:EMSDK) {
            $bundled = Join-Path $env:EMSDK "upstream\bin\llvm-profdata.exe"
            if (Test-Path $bundled) { $ProfdataExe = $bundled }
        }
        if ($ProfdataExe -eq "" -or -not (Test-Path $ProfdataExe)) { throw "set -ProfdataExe to an llvm-profdata matching the emsdk clang (e.g. <emsdk>\upstream\bin\llvm-profdata.exe)" }
        Write-Host "training on test/ corpus (instrumented build)..."
        Invoke-Emcc "-O2 -DNDEBUG -fprofile-instr-generate=build/train.profraw -sEXIT_RUNTIME=1 -s ALLOW_MEMORY_GROWTH=1 -std=c11 -w -D_DEFAULT_SOURCE -I. $srcs tools/train.c $ProfileRt -o build/train.js -sNODERAWFS=1" "trainer build"
        & node build/train.js
        if ($LASTEXITCODE) { throw "training run failed" }
        # powershell 5.1 splits `-output=x` style arguments; go through cmd
        cmd /c "`"$ProfdataExe`" merge -output=build/pgo-wasm.profdata build/train.profraw"
        if ($LASTEXITCODE) { throw "profdata merge failed" }
        Write-Host "PGO profile written to build/pgo-wasm.profdata"
        Remove-Item build/train.profraw -ErrorAction SilentlyContinue
        if (-not $PGO) { return }
    }

    # current: same codegen flags as the shipped build/libverify.wasm
    # (-gseparate-dwarf keeps binaryen's slower postlink passes out)
    $currentFlags = "-O3 -flto -gseparate-dwarf -DNDEBUG"
    if ($PGO) {
        if (-not (Test-Path "build/pgo-wasm.profdata")) { throw "build/pgo-wasm.profdata missing; run with -Train first" }
        $currentFlags = "$currentFlags -fprofile-instr-use=build/pgo-wasm.profdata"
    }
    $pgolabel = if ($PGO) { " + PGO" } else { "" }

    Write-Host "building current (extension, -O3 -flto$pgolabel)..."
    Invoke-Emcc "$currentFlags -std=c11 -w -D_DEFAULT_SOURCE -I. $srcs tools/bench.c -o build/bench-current.js -sNODERAWFS=1" "current build"

    $sha = (& git rev-parse --short "$Base^{commit}").Trim()
    $cache = "build/bench-cache/$sha"
    if (-not (Test-Path "$cache/sim.c")) {
        Write-Host "extracting baseline sources ($Base @ $sha)..."
        New-Item -ItemType Directory -Force -Path $cache | Out-Null
        foreach ($f in $srcs.Split(" ") + @("collision.h", "decode.h", "parse.h", "sim.h", "steady-state.h", "verifier.h")) {
            $content = & git show "${Base}:$f" | Out-String
            [System.IO.File]::WriteAllText("$root/$cache/$f", $content, [System.Text.Encoding]::ASCII)
        }
    }
    Write-Host "building baseline ($sha, -O2, collision detection always on)..."
    # compile the cached baseline sources (not the working tree!) against the
    # cached baseline headers
    $srcArgs = ($srcs.Split(" ") | ForEach-Object { "$cache/$_" }) -join " "
    Invoke-Emcc "-O2 -DNDEBUG -std=c11 -w -D_DEFAULT_SOURCE -DNO_COLL_API -I$cache $srcArgs tools/bench.c -o build/bench-base.js -sNODERAWFS=1" "baseline build"

    Write-Host "== baseline ($sha, -O2, collision detection always on) =="
    & node build/bench-base.js $Puzzle $Solution $Cycles $Repeats
    Write-Host "== current (collision detection on$pgolabel) =="
    & node build/bench-current.js $Puzzle $Solution $Cycles $Repeats 0
    Write-Host "== current (collision detection OFF$pgolabel) =="
    & node build/bench-current.js $Puzzle $Solution $Cycles $Repeats 1
}
finally {
    Pop-Location
}
