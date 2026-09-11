.PHONY: clean

CFLAGS=-O3 -flto -std=c11 -pedantic -Wall -Wno-missing-braces
# override with `make NATIVE=` for portable (non-host-specific) native builds
NATIVE=-march=native
LDLIBS=-lm
# use the Homebrew clang when present (mac), else whatever clang is on PATH
LLVMCC=$(if $(wildcard /opt/homebrew/Cellar/llvm/17.0.6/bin/clang),/opt/homebrew/Cellar/llvm/17.0.6/bin/clang,clang)
EMFLAGS=--no-entry -s ALLOW_MEMORY_GROWTH=1 -s ALLOW_TABLE_GROWTH=1 --profiling-funcs -DNDEBUG
# exported symbols for the emscripten FFI build, whitespace separated and
# grouped like verifier.h; joined into a comma separated list by $(csv).
comma := ,
csv = $(if $(wordlist 2,2,$(1)),$(firstword $(1))$(comma)$(call csv,$(wordlist 2,$(words $(1)),$(1))),$(1))

EMEXPORTS_SYMBOLS := \
    _malloc \
    _free \
    _verifier_create_from_bytes _verifier_create_from_bytes_without_copying \
    _verifier_destroy \
    _verifier_set_cycle_limit _verifier_set_collision_check_limit \
    _verifier_set_collision_detection _verifier_disable_limits \
    _verifier_error _verifier_error_clear _verifier_error_cycle \
    _verifier_error_source _verifier_error_location_u _verifier_error_location_v \
    _verifier_evaluate_metric _verifier_evaluate_approximate_metric \
    _verifier_measure_current \
    _verifier_set_fails_on_wrong_output _verifier_set_fails_on_wrong_output_bonds \
    _verifier_wrong_output_index _verifier_wrong_output_atom _verifier_wrong_output_clear \
    _verifier_number_of_output_intervals _verifier_output_interval \
    _verifier_output_intervals_repeat_after \
    _verifier_advance _verifier_current_cycle _verifier_completed _verifier_converged \
    _verifier_find_puzzle_name_in_solution_bytes
EMEXPORTS := $(call csv,$(EMEXPORTS_SYMBOLS))

HEADER=collision.h decode.h parse.h sim.h steady-state.h verifier.h
SOURCE=collision.c decode.c parse.c sim.c steady-state.c verifier.c

BUILD_DIR=build
ifeq ($(OS),Windows_NT)
# mingw clang appends .exe to extensionless -o names; make's dependency
# tracking needs the exact file name, so spell it out (unix: empty)
EXE=.exe
MKDIR_BUILD = @if not exist "$(BUILD_DIR)" mkdir "$(BUILD_DIR)"
else
MKDIR_BUILD = @mkdir -p $(BUILD_DIR)
endif

# libverify.so / libverify.dll / libverify.wasm are PGO-optimized by default:
# `make libverify.so` first builds an instrumented trainer (tools/train.c),
# runs it over the test/ corpus (natively, or as wasm under node for the wasm
# library), merges the raw profile with llvm-profdata, then links the library
# with -fprofile-instr-use.  everything is dependency-tracked, so retraining
# happens automatically when sources or the corpus change.  `make libverify.so
# PGO=0` skips profiling for a plain -O3 build.
ifeq ($(PGO),0)
SO_PGO_DEPS =
SO_PGO_FLAGS =
WASM_PGO_DEPS =
WASM_PGO_FLAGS =
else
SO_PGO_DEPS = $(BUILD_DIR)/pgo.profdata
SO_PGO_FLAGS = -fprofile-instr-use=$(BUILD_DIR)/pgo.profdata
WASM_PGO_DEPS = $(BUILD_DIR)/pgo-wasm.profdata
WASM_PGO_FLAGS = -fprofile-instr-use=$(BUILD_DIR)/pgo-wasm.profdata
endif

$(BUILD_DIR)/omsim$(EXE): $(HEADER) $(SOURCE) Makefile main.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(NATIVE) -g -D_DEFAULT_SOURCE -o $@ $(SOURCE) main.c $(LDLIBS)

$(BUILD_DIR)/libverify.so $(BUILD_DIR)/libverify.dll: $(HEADER) $(SOURCE) Makefile $(SO_PGO_DEPS) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(NATIVE) -g $(SO_PGO_FLAGS) -shared -fpic -o $@ $(SOURCE) $(LDLIBS)

$(BUILD_DIR)/libverify.wasm: $(HEADER) $(SOURCE) Makefile $(WASM_PGO_DEPS) | $(BUILD_DIR)
	emcc $(CFLAGS) $(EMFLAGS) $(WASM_PGO_FLAGS) -gseparate-dwarf -s EXPORTED_FUNCTIONS=$(EMEXPORTS) -o $@ $(SOURCE)

$(BUILD_DIR)/run-tests$(EXE): $(HEADER) $(SOURCE) Makefile run-tests.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(NATIVE) -g -D_DEFAULT_SOURCE -o $@ $(SOURCE) run-tests.c $(LDLIBS)

# libFuzzer on Windows: mingw clang gates -fsanitize=fuzzer (and even
# -fsanitize=fuzzer-no-link) off, so hand-roll its coverage flags and link
# the fuzzer archive from the clang installation found on PATH, plus the
# libc++ runtime the archive is built against
ifeq ($(OS),Windows_NT)
FUZZER_LIB = $(firstword $(foreach d,$(subst ;, ,$(subst \,/,$(PATH))),$(wildcard $(d)/../lib/clang/*/lib/windows/libclang_rt.fuzzer-x86_64.a)))
LIBFUZZER_FLAGS = -fsanitize=address -fsanitize-coverage=inline-8bit-counters,indirect-calls,trace-cmp
FUZZER_LIBS = $(FUZZER_LIB) -lc++ -lunwind
# -flto hits "Associative COMDAT symbol ... is not a key for its COMDAT"
# (llvm COFF LTO bug) when linking the fuzzer archive
FUZZER_CFLAGS = $(subst -flto,,$(CFLAGS))
else
LIBFUZZER_FLAGS = -fsanitize=fuzzer,address
FUZZER_LIBS =
FUZZER_CFLAGS = $(CFLAGS)
endif

$(BUILD_DIR)/llvm-fuzz$(EXE): $(HEADER) $(SOURCE) Makefile llvm-fuzz.c | $(BUILD_DIR)
	$(LLVMCC) $(FUZZER_CFLAGS) -g $(LIBFUZZER_FLAGS) -o $@ llvm-fuzz.c $(SOURCE) $(LDLIBS) $(FUZZER_LIBS)

$(BUILD_DIR):
	$(MKDIR_BUILD)

clean:
	-rm -rf $(BUILD_DIR)

# native PGO automation (wired into the default libverify.so rule above):
# the profile is trained from the test/ corpus (ON+OFF passes over every
# solution, see tools/train.c).  needs llvm-profdata matching the native
# clang (clang-only; gcc uses different flags), override with e.g.
# `make libverify.so LLVMPROFDATA="xcrun -f llvm-profdata"`.
# PGO is tied to the source revision: after changing any simulator source,
# retrain.
# raw profiles are version-locked to the clang that wrote them, so wasm
# profiles must be merged with the llvm-profdata bundled in the emsdk that
# provides emcc (the system LLVM is often too old).  discovery uses
# $(wildcard) on $EMSDK so it stays shell-agnostic: on Windows $(shell)
# runs cmd.exe when Git Bash is not on PATH.
ifeq ($(OS),Windows_NT)
EMSDK_M = $(subst \,/,$(EMSDK))
# find emsdk's bundled profdata: rooted at $EMSDK when set, else scan PATH
# for an emcc sibling (upstream/emscripten/../bin).  pure $(wildcard), no
# $(shell) -- GnuWin32 make runs $(shell) via cmd.exe when sh is absent,
# and PATH entries containing spaces simply split into harmless fragments.
WASMPROFDATA ?= $(or $(wildcard $(EMSDK_M)/upstream/bin/llvm-profdata.exe),$(firstword $(foreach d,$(subst ;, ,$(subst \,/,$(PATH))),$(wildcard $(d)/../bin/llvm-profdata.exe $(d)/llvm-profdata.exe))))
# native pgo profiles, in contrast, must match the native clang (CC)
LLVMPROFDATA ?= llvm-profdata
else
WASMPROFDATA ?= $(wildcard $(EMSDK)/upstream/bin/llvm-profdata)
LLVMPROFDATA ?= $(shell command -v llvm-profdata 2>/dev/null || xcrun -f llvm-profdata 2>/dev/null || echo llvm-profdata)
endif
# merge tool for the wasm raw profiles: emsdk's own profdata when found
PROFDATA_TOOL = $(if $(WASMPROFDATA),$(WASMPROFDATA),$(LLVMPROFDATA))
NODE ?= node
# training corpus: adding or changing test data retrains the profile on the
# next `make pgo` / `make pgo-wasm`.  (unix only -- Windows find.exe does not
# speak POSIX; retrain manually there.  the sed escaping is how make copes
# with spaces in corpus paths like "Week 8")
ifeq ($(OS),Windows_NT)
CORPUS=
else
CORPUS=$(shell find test -type f \( -name '*.puzzle' -o -name '*.solution' \) 2>/dev/null | sed 's/ /\\ /g')
endif

# `make libverify.so` / `make libverify.dll` / `make libverify.wasm` work
# like upstream: one command from a clean tree trains the PGO profile and
# links the optimized library.  `pgo` / `pgo-wasm` are kept as aliases; the
# remaining upstream-style names just point into build/ (without these,
# `make llvm-fuzz` etc. would hit make's built-in single-file %: %.c rule
# and fail to link).
.PHONY: pgo pgo-wasm libverify.so libverify.dll libverify.wasm omsim run-tests llvm-fuzz
pgo: $(BUILD_DIR)/libverify.so
pgo-wasm: $(BUILD_DIR)/libverify.wasm
libverify.so: $(BUILD_DIR)/libverify.so
libverify.dll: $(BUILD_DIR)/libverify.dll
libverify.wasm: $(BUILD_DIR)/libverify.wasm
omsim: $(BUILD_DIR)/omsim$(EXE)
run-tests: $(BUILD_DIR)/run-tests$(EXE)
llvm-fuzz: $(BUILD_DIR)/llvm-fuzz$(EXE)

# wasm PGO automation (wired into the default libverify.wasm rule above;
# alias `make pgo-wasm`): the profile is trained from the test/ corpus with
# a wasm trainer running under node (ON+OFF passes over every solution).
# needs the emsdk environment sourced (`source .../emsdk_env.sh` /
# `emsdk_env.bat`) for emcc and node.  the profile runtime archive that
# emsdk does not ship is built on first use by tools/pgo-wasm-rt.sh (unix) /
# .ps1 (Windows); needs git + network once, pinned to the revision of the
# active emsdk clang (auto-detected, falls back to LLVM 21).
ifeq ($(OS),Windows_NT)
PGO_RT_CMD = powershell -ExecutionPolicy Bypass -File tools/pgo-wasm-rt.ps1
else
PGO_RT_CMD = sh ./tools/pgo-wasm-rt.sh
endif

# merge a raw profile into $@ with $(1).  raw profiles are version-locked to
# the clang that wrote them: wasm profiles need emsdk's bundled profdata,
# native profiles one matching the native clang.  $(call
# PROFDATA_MERGE,<profdata-tool>,<profraw>).
ifeq ($(OS),Windows_NT)
PROFDATA_MERGE = $(1) merge -output=$@ $(2) || (echo "error: profile merge failed -- llvm-profdata too old for the raw profile; merge with the profdata bundled in <emsdk>/upstream/bin (must match the clang that wrote the profile), e.g. make pgo-wasm LLVMPROFDATA=<path>" 1>&2 & exit 1)
else
PROFDATA_MERGE = $(1) merge -output=$@ $(2) || (echo "error: profile merge failed -- llvm-profdata too old for the raw profile; merge with the profdata bundled in <emsdk>/upstream/bin (must match the clang that wrote the profile), e.g. make pgo-wasm LLVMPROFDATA=<path>" 1>&2; exit 1)
endif

$(BUILD_DIR)/libclang_rt.profile-emscripten.a:
	$(PGO_RT_CMD)

$(BUILD_DIR)/train-wasm.js: $(HEADER) $(SOURCE) tools/train.c Makefile $(BUILD_DIR)/libclang_rt.profile-emscripten.a | $(BUILD_DIR)
	emcc $(CFLAGS) -DNDEBUG -D_DEFAULT_SOURCE -I. -fprofile-instr-generate=$(BUILD_DIR)/train-wasm.profraw -sEXIT_RUNTIME=1 -sNODERAWFS=1 -sALLOW_MEMORY_GROWTH=1 $(SOURCE) tools/train.c $(BUILD_DIR)/libclang_rt.profile-emscripten.a -o $@

$(BUILD_DIR)/pgo-wasm.profdata: $(BUILD_DIR)/train-wasm.js $(CORPUS)
	-rm -f $(BUILD_DIR)/train-wasm.profraw
	$(NODE) $<
	$(call PROFDATA_MERGE,$(PROFDATA_TOOL),$(BUILD_DIR)/train-wasm.profraw)

$(BUILD_DIR)/train-native$(EXE): $(HEADER) $(SOURCE) tools/train.c Makefile | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(NATIVE) -DNDEBUG -fprofile-instr-generate=$(BUILD_DIR)/train.profraw -D_DEFAULT_SOURCE -I. $(SOURCE) tools/train.c -o $@ $(LDLIBS)

$(BUILD_DIR)/pgo.profdata: $(BUILD_DIR)/train-native$(EXE) $(CORPUS)
	-rm -f $(BUILD_DIR)/train.profraw
	./$<
	$(call PROFDATA_MERGE,$(LLVMPROFDATA),$(BUILD_DIR)/train.profraw)
