.PHONY: clean

CFLAGS=-O3 -flto -std=c11 -pedantic -Wall -Wno-missing-braces
# override with `make NATIVE=` for portable (non-host-specific) native builds
NATIVE=-march=native
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

$(BUILD_DIR)/libverify.so $(BUILD_DIR)/libverify.dll: $(HEADER) $(SOURCE) Makefile | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(NATIVE) -g -shared -fpic -o $@ $(SOURCE) $(LDLIBS)

$(BUILD_DIR)/libverify.wasm: $(HEADER) $(SOURCE) Makefile | $(BUILD_DIR)
	emcc $(CFLAGS) $(EMFLAGS) -s EXPORTED_FUNCTIONS=$(EMEXPORTS) -o $@ $(SOURCE)

$(BUILD_DIR)/run-tests: $(HEADER) $(SOURCE) Makefile run-tests.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(NATIVE) -g -D_DEFAULT_SOURCE -o $@ $(SOURCE) run-tests.c $(LDLIBS)

$(BUILD_DIR)/llvm-fuzz: $(HEADER) $(SOURCE) Makefile llvm-fuzz.c | $(BUILD_DIR)
	$(LLVMCC) $(CFLAGS) -g -fsanitize=fuzzer,address -o $@ llvm-fuzz.c $(SOURCE) $(LDLIBS)

$(BUILD_DIR):
	$(MKDIR_BUILD)

clean:
	-rm -rf $(BUILD_DIR)
