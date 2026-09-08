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
# corpus (ON+OFF passes over every solution, see benchmark/train.c) and then
# rebuilds the PGO-optimized shared library with it.  needs llvm-profdata
# matching the native clang (clang-only; gcc uses different flags), override
# with e.g. `make pgo LLVMPROFDATA="xcrun -f llvm-profdata"`.  run plain
# `make pgo` (not PGO=1 pgo).
# PGO is tied to the source revision: after changing any simulator source,
# retrain.  wasm PGO additionally needs `make pgo-rt` once (see below).
ifeq ($(OS),Windows_NT)
LLVMPROFDATA ?= llvm-profdata
else
LLVMPROFDATA ?= $(shell command -v llvm-profdata 2>/dev/null || xcrun -f llvm-profdata 2>/dev/null || echo llvm-profdata)
endif

.PHONY: pgo pgo-rt
pgo: $(BUILD_DIR)/pgo.profdata
	$(CC) $(CFLAGS) $(NATIVE) -g -fprofile-instr-use=$(BUILD_DIR)/pgo.profdata -shared -fpic -o $(BUILD_DIR)/libverify.so $(SOURCE) $(LDLIBS)

# build the wasm profile runtime archive that emsdk does not ship
# (scripts the compiler-rt build; needs emcc + git + network, pinned to LLVM 21)
pgo-rt:
	sh ./tools/pgo-wasm-rt.sh

$(BUILD_DIR)/train-native: $(HEADER) $(SOURCE) benchmark/train.c Makefile | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(NATIVE) -DNDEBUG -fprofile-instr-generate=$(BUILD_DIR)/train.profraw -D_DEFAULT_SOURCE -I. $(SOURCE) benchmark/train.c -o $@

$(BUILD_DIR)/pgo.profdata: $(BUILD_DIR)/train-native
	-rm -f $(BUILD_DIR)/train.profraw
	./$(BUILD_DIR)/train-native
	$(LLVMPROFDATA) merge -output=$@ $(BUILD_DIR)/train.profraw
