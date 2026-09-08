.PHONY: clean

CFLAGS=-O3 -flto -std=c11 -pedantic -Wall -Wno-missing-braces
# override with `make NATIVE=` for portable (non-host-specific) native builds
NATIVE=-march=native
# PGO consumption: after training, build with `make PGO=1 PROFDATA=build/pgo.profdata <target>`.
# profile recipe:  1) build instrumented artifacts (add -fprofile-instr-generate=<profraw>
#                  -sEXIT_RUNTIME=1 for wasm, plus a libclang_rt.profile archive --
#                  emsdk lacks it; build compiler-rt/lib/profile sources with emcc,
#                  use InstrProfilingPlatformLinux.c and stub lprofGetHostName)
#                  2) run representative workloads, 3) llvm-profdata merge.
# native clang links its own profile runtime; no extra archive needed.
ifeq ($(PGO),1)
CFLAGS+=-fprofile-instr-use=$(PROFDATA)
EXTRA_DEPS+=$(PROFDATA)
endif
LDLIBS=-lm
LLVMCC=/opt/homebrew/Cellar/llvm/17.0.6/bin/clang
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
MKDIR_BUILD = @if not exist "$(BUILD_DIR)" mkdir "$(BUILD_DIR)"
else
MKDIR_BUILD = @mkdir -p $(BUILD_DIR)
endif

$(BUILD_DIR)/omsim: $(HEADER) $(SOURCE) Makefile main.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(NATIVE) -g -D_DEFAULT_SOURCE -o $@ $(SOURCE) main.c $(LDLIBS)

$(BUILD_DIR)/libverify.so $(BUILD_DIR)/libverify.dll: $(HEADER) $(SOURCE) Makefile $(EXTRA_DEPS) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(NATIVE) -g -shared -fpic -o $@ $(SOURCE) $(LDLIBS)

$(BUILD_DIR)/libverify.wasm: $(HEADER) $(SOURCE) Makefile | $(BUILD_DIR)
	emcc $(CFLAGS) $(EMFLAGS) -gseparate-dwarf -s EXPORTED_FUNCTIONS=$(EMEXPORTS) -o $@ $(SOURCE)

$(BUILD_DIR)/run-tests: $(HEADER) $(SOURCE) Makefile run-tests.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(NATIVE) -g -D_DEFAULT_SOURCE -o $@ $(SOURCE) run-tests.c $(LDLIBS)

$(BUILD_DIR)/llvm-fuzz: $(HEADER) $(SOURCE) Makefile llvm-fuzz.c | $(BUILD_DIR)
	$(LLVMCC) $(CFLAGS) -g -fsanitize=fuzzer,address -o $@ llvm-fuzz.c $(SOURCE) $(LDLIBS)

$(BUILD_DIR):
	$(MKDIR_BUILD)

clean:
	-rm -rf $(BUILD_DIR)

# native PGO automation: `make pgo` retrains the profile from the test/
# corpus (ON+OFF passes over every solution, see tools/train.c) and then
# rebuilds the PGO-optimized shared library with it.  needs llvm-profdata
# matching the native clang (clang-only; gcc uses different flags), override
# with e.g. `make pgo LLVMPROFDATA="xcrun -f llvm-profdata"`.  run plain
# `make pgo` (not PGO=1 pgo).
# PGO is tied to the source revision: after changing any simulator source,
# retrain.
ifeq ($(OS),Windows_NT)
LLVMPROFDATA ?= llvm-profdata
else
LLVMPROFDATA ?= $(shell command -v llvm-profdata 2>/dev/null || xcrun -f llvm-profdata 2>/dev/null || echo llvm-profdata)
endif
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

.PHONY: pgo pgo-wasm
pgo: $(BUILD_DIR)/pgo.profdata
	$(CC) $(CFLAGS) $(NATIVE) -g -fprofile-instr-use=$(BUILD_DIR)/pgo.profdata -shared -fpic -o $(BUILD_DIR)/libverify.so $(SOURCE) $(LDLIBS)

# wasm PGO automation: `make pgo-wasm` retrains the profile from the test/
# corpus with a wasm trainer running under node (ON+OFF passes over every
# solution) and then rebuilds the PGO-optimized libverify.wasm with it.
# needs the emsdk environment sourced (`source .../emsdk_env.sh`) for emcc
# and node.  the profile runtime archive that emsdk does not ship is built
# on first use by tools/pgo-wasm-rt.sh (needs git + network once, pinned to
# LLVM 21; works with emsdk 5 / LLVM 22 clang too).
$(BUILD_DIR)/libclang_rt.profile-emscripten.a:
	sh ./tools/pgo-wasm-rt.sh

$(BUILD_DIR)/train-wasm.js: $(HEADER) $(SOURCE) tools/train.c Makefile $(BUILD_DIR)/libclang_rt.profile-emscripten.a | $(BUILD_DIR)
	emcc $(CFLAGS) -DNDEBUG -D_DEFAULT_SOURCE -I. -fprofile-instr-generate=$(BUILD_DIR)/train-wasm.profraw -sEXIT_RUNTIME=1 -sNODERAWFS=1 -sALLOW_MEMORY_GROWTH=1 $(SOURCE) tools/train.c $(BUILD_DIR)/libclang_rt.profile-emscripten.a -o $@

$(BUILD_DIR)/pgo-wasm.profdata: $(BUILD_DIR)/train-wasm.js $(CORPUS)
	-rm -f $(BUILD_DIR)/train-wasm.profraw
	$(NODE) $<
	$(LLVMPROFDATA) merge -output=$@ $(BUILD_DIR)/train-wasm.profraw

pgo-wasm: $(BUILD_DIR)/pgo-wasm.profdata
	emcc $(CFLAGS) $(EMFLAGS) -fprofile-instr-use=$(BUILD_DIR)/pgo-wasm.profdata -gseparate-dwarf -s EXPORTED_FUNCTIONS=$(EMEXPORTS) -o $(BUILD_DIR)/libverify.wasm $(SOURCE)

$(BUILD_DIR)/train-native: $(HEADER) $(SOURCE) tools/train.c Makefile | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(NATIVE) -DNDEBUG -fprofile-instr-generate=$(BUILD_DIR)/train.profraw -D_DEFAULT_SOURCE -I. $(SOURCE) tools/train.c -o $@ $(LDLIBS)

$(BUILD_DIR)/pgo.profdata: $(BUILD_DIR)/train-native $(CORPUS)
	-rm -f $(BUILD_DIR)/train.profraw
	./$(BUILD_DIR)/train-native
	$(LLVMPROFDATA) merge -output=$@ $(BUILD_DIR)/train.profraw
