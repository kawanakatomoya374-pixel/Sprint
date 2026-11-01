# Sprint 2.0 reference implementation
#
#   make            strict release build (-Werror, hardened)
#   make debug      strict build with ASan + UBSan, no optimisation
#   make analyze    GCC static analyzer (-fanalyzer), also -Werror
#   make test       run regression tests against the release binary
#   make test-san   run regression tests against the sanitizer binary
#   make clean
#
# Every warning is an error. Flags that are deliberately NOT enabled are listed
# at the bottom with the reason.

CC       ?= gcc
BUILD    ?= build
.DEFAULT_GOAL := all
GEN      := $(BUILD)/gen
STDSRC   := $(wildcard stdlib/*.sp)
# gui is kept as ordered parts (stdlib/gui/NN_*.sp) and embedded as one module
GUIPARTS := $(sort $(wildcard stdlib/gui/*.sp))

# ---- compiler probing ---------------------------------------------------------
# Flags that only newer GCCs know are added when the compiler in use accepts them, so an older GCC (9 and later) still builds.
# `make WERROR=` turns the warnings into plain warnings (another compiler may have different false positives).
cc-opt   = $(shell $(CC) $(1) -x c -c /dev/null -o /dev/null >/dev/null 2>&1 && echo $(1))
WERROR   ?= -Werror
OPT_WARN := $(foreach f,-Wstrict-flex-arrays -Warray-compare -Warith-conversion -Wc11-c2x-compat -Wattribute-alias=2 \
                        -Wmultistatement-macros -Wfree-nonheap-object -Wcast-align=strict -Wimplicit-fallthrough=5 \
                        -Wcast-function-type -Walloc-zero -Walloc-size -Wvla-larger-than=0 -Wmissing-noreturn -Wstringop-overread \
                        -Wenum-conversion -Wabsolute-value -Wmissing-format-attribute -Wdeprecated-non-prototype \
                        -Wstack-usage=32768 -Wshadow=local -Wtrivial-auto-var-init,$(call cc-opt,$(f)))
OPT_HARD := $(foreach f,-fstrict-flex-arrays=3 -ftrivial-auto-var-init=zero -fcf-protection=full -fwrapv-pointer -fstack-clash-protection -fno-plt,$(call cc-opt,$(f)))
# without -ftrivial-auto-var-init (GCC 12+) older compilers report possible uninitialised reads in a few output-parameter
# idioms (lib_gfx.c); the locals are initialised on every path that uses them, so that one warning stays a warning there
ifeq ($(findstring -ftrivial-auto-var-init=zero,$(OPT_HARD)),)
WERROR += -Wno-error=maybe-uninitialized
endif

# ---- language / diagnostics -------------------------------------------------
STD      := -std=c11 -pedantic-errors
WARN     := $(WERROR) $(OPT_WARN) -Wall -Wextra \
            -Wconversion -Wsign-conversion -Wdouble-promotion \
            -Wshadow -Wundef -Wpointer-arith -Wcast-qual \
            -Wwrite-strings -Wvla -Walloca -Wredundant-decls -Wnested-externs \
            -Wstrict-prototypes -Wold-style-definition \
            -Wmissing-prototypes -Wmissing-declarations \
            -Wformat=2 -Wformat-signedness -Wformat-overflow=2 -Wformat-truncation=2 \
            -Wnull-dereference -Wduplicated-cond -Wduplicated-branches -Wlogical-op \
            -Wswitch-default -Wjump-misses-init \
            -Wbad-function-cast -Wstrict-aliasing=2 -Warray-bounds=2 \
            -Wstringop-overflow=4 -Wshift-overflow=2 -Wunused-macros \
            -Wmissing-include-dirs -Wtrampolines -Wunsafe-loop-optimizations \
            -Wstack-protector -Winvalid-pch \
            -Wfloat-equal -Wswitch-enum -Wpacked -Wdate-time -Wdisabled-optimization \
            -Wunused-const-variable=2 -Wuninitialized \
            -Wmaybe-uninitialized -Wcomment \
            -Wtrigraphs -Wdangling-else \
            -Wsizeof-array-argument -Wsizeof-pointer-memaccess -Wpointer-compare \
            -Wint-in-bool-context -Wmisleading-indentation -Wparentheses \
            -Wframe-larger-than=65536 -Wlarger-than=8388608 \
            -Wsuggest-attribute=format -Wsuggest-attribute=noreturn \
            -Wno-error=unsafe-loop-optimizations \
            -Wno-unknown-warning-option

# ---- hardening ---------------------------------------------------------------
HARDEN   := -fstack-protector-strong -D_FORTIFY_SOURCE=3 -fno-common -fno-strict-overflow \
            -fno-delete-null-pointer-checks $(OPT_HARD) -fPIE
# Fail closed on unresolved symbols or linker diagnostics, and keep executable
# code in a separate segment in addition to PIE/RELRO/NX hardening.
LDHARDEN := -pie -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack \
            -Wl,-z,separate-code -Wl,-z,defs -Wl,--fatal-warnings -Wl,--as-needed -Wl,-z,nodump \
            -Wl,--no-copy-dt-needed-entries -Wl,-O1 -Wl,--sort-common -Wl,--hash-style=gnu

INC      := -Isrc
comma    := ,
TUNE_FLAG := -mtune-ctrl=^sse_unaligned_load_optimal$(comma)^sse_unaligned_store_optimal
TUNE     := $(if $(filter x86_64,$(shell uname -m)),$(shell $(CC) $(TUNE_FLAG) -x c -c /dev/null -o /dev/null >/dev/null 2>&1 && echo $(TUNE_FLAG)),)
PGO      ?=
CFLAGS_REL := $(STD) $(WARN) $(HARDEN) -O2 $(TUNE) -g $(INC) -DNDEBUG_SP $(PGO)
CFLAGS_DBG := $(STD) $(WARN) $(HARDEN) -O0 -g3 $(INC) \
              -fsanitize=address,undefined -fno-sanitize-recover=undefined \
              -fsanitize=bounds-strict,float-cast-overflow -fstack-protector-all -fno-omit-frame-pointer
LDFLAGS_DBG := -fsanitize=address,undefined

FRONT_SRC   := src/front/lexer.c src/front/parser.c src/front/parse_expr.c src/front/compiler.c src/front/cmp_util.c src/front/cmp_expr.c src/front/cmp_stmt.c src/front/cmp_class.c src/front/cmp_import.c src/front/disasm.c src/front/loader.c
RUNTIME_SRC := src/runtime/value.c src/runtime/table.c src/runtime/format.c \
               src/runtime/gc.c src/runtime/vm_core.c src/runtime/vm.c \
               src/runtime/vm/quickening.c src/runtime/vm/class.c \
               src/runtime/vm/trace_record.c src/runtime/image.c \
               src/runtime/sha256.c src/runtime/verify.c src/runtime/embed.c \
               src/runtime/trace_ir.c src/runtime/jit/regalloc.c src/runtime/jit/snapshot.c \
               src/runtime/jit.c src/runtime/jit_trace.c
LIB_SRC     := src/lib/lib.c src/lib/lib_math.c src/lib/lib_str.c src/lib/lib_array.c src/lib/lib_table.c src/lib/lib_sys.c src/lib/lib_co.c src/lib/lib_ext.c src/lib/lib_gfx.c src/lib/font_ja.c src/lib/lib_ffi.c src/lib/lib_typed.c
LIBSRC := $(FRONT_SRC) $(RUNTIME_SRC) $(LIB_SRC) $(GEN)/bundled.c
CLISRC := cli/main.c cli/tool_fmt.c cli/tool_lint.c cli/repl.c
ALLSRC := $(LIBSRC) $(CLISRC)

REL_OBJ := $(patsubst %.c,$(BUILD)/rel/%.o,$(ALLSRC))
DBG_OBJ := $(patsubst %.c,$(BUILD)/dbg/%.o,$(ALLSRC))

$(GEN)/gui.sp: $(GUIPARTS)
	@mkdir -p $(GEN)
	cat $(GUIPARTS) > $@

$(GEN)/bundled.c: tools/embedsrc.c $(STDSRC) $(GEN)/gui.sp Makefile
	@mkdir -p $(GEN)
	$(CC) -O1 -o $(GEN)/embedsrc tools/embedsrc.c
	$(GEN)/embedsrc $@ gui=$(GEN)/gui.sp $(foreach f,$(STDSRC),$(basename $(notdir $(f)))=$(f))

# Profile-guided build (build/sprint-pgo): instrument, train on the benchmarks and the language tests, rebuild with the profile.
# Slower to build, ~5-10% faster interpreter and JIT runtime. The default `make` stays profile-free and reproducible.
pgo:
	rm -rf $(BUILD)/pgo
	$(MAKE) BUILD=$(BUILD)/pgo PGO="-fprofile-generate -fprofile-update=single" $(BUILD)/pgo/sprint
	sh tools/pgo_train.sh $(BUILD)/pgo/sprint
	find $(BUILD)/pgo -name '*.o' -delete
	rm -f $(BUILD)/pgo/sprint
	$(MAKE) BUILD=$(BUILD)/pgo PGO="-fprofile-use -fprofile-correction -Wno-error=coverage-mismatch -Wno-missing-profile" $(BUILD)/pgo/sprint
	cp $(BUILD)/pgo/sprint $(BUILD)/sprint-pgo
.PHONY: pgo

.PHONY: all debug analyze test test-san test-embed test-gc-stress test-gc-stack-growth test-gc-stats test-gc-stress-san test-gc-stack-growth-san test-gc-stats-san fuzz bench clean lib
all: $(BUILD)/sprint

lib: $(BUILD)/libsprint.a

$(BUILD)/libsprint.a: $(filter-out $(BUILD)/rel/cli/%,$(REL_OBJ))
	rm -f $@
	ar rcs $@ $^

debug: $(BUILD)/sprint-san

$(BUILD)/sprint: $(REL_OBJ)
	$(CC) $(CFLAGS_REL) $(LDHARDEN) -o $@ $^ -lm -ldl

$(BUILD)/sprint-san: $(DBG_OBJ)
	$(CC) $(CFLAGS_DBG) -o $@ $^ -lm -ldl $(LDFLAGS_DBG)

# The interpreter loop is the one file where -fno-strict-overflow costs ~30% (it blocks loop and branch folding in the
# dispatch switch). vm.c does not rely on signed wrap-around: every checked operation uses unsigned or builtin overflow
# helpers, and the UBSan build runs the whole suite. vm.c alone therefore uses the compiler default.
# Same reasoning for control-flow protection: every computed-goto handler is an indirect-branch target, and -fcf-protection=full
# plants an endbr64 at each of them. The targets are labels inside this one function (a jump table of constants, never a
# function pointer from data), so vm.o alone is built with -fcf-protection=none; everything else keeps =full.
VMEXTRA ?= -fcf-protection=none
$(BUILD)/rel/src/runtime/vm.o: CFLAGS_REL += -fstrict-overflow $(VMEXTRA)

$(BUILD)/rel/%.o: %.c src/sp.h src/sprint.h Makefile
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_REL) -MMD -c -o $@ $<

$(BUILD)/dbg/%.o: %.c src/sp.h src/sprint.h Makefile
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_DBG) -MMD -c -o $@ $<

# image fuzzer (ASan + UBSan): make fuzz IMAGE=x.spc ITER=20000 SEED=1
IMAGE ?= build/fuzz-seed.spc
ITER  ?= 5000
SEED  ?= 1
fuzz: $(BUILD)/sprint-san
	$(CC) $(CFLAGS_DBG) -o $(BUILD)/fuzz-image tools/fuzz_image.c $(filter-out $(BUILD)/dbg/cli/%,$(DBG_OBJ)) -lm -ldl $(LDFLAGS_DBG)
	@for t in class coroutine defer2 closures match sort hof iter errors cls_super2 json; do \
	  $(BUILD)/sprint-san compile -o $(BUILD)/fuzz-seed.spc $$(ls tests/cases/*/$$t.sp) && \
	  ASAN_OPTIONS=detect_leaks=0 $(BUILD)/fuzz-image $(BUILD)/fuzz-seed.spc $(ITER) $(SEED) || exit 1; \
	done

analyze: $(GEN)/bundled.c
	@for f in $(ALLSRC); do \
	  echo "analyze $$f"; \
	  $(CC) $(STD) $(WARN) -O1 $(INC) -fanalyzer $(call cc-opt,-fstrict-flex-arrays=3) -Wno-analyzer-malloc-leak \
	    -fsyntax-only $$f || exit 1; \
	done

# clang -Weverything (minus the checks that contradict this code base on purpose: unsafe-buffer-usage wants span types,
# padded is the explicit ABI padding of SpValue, declaration-after-statement is C89 style, the C++98/pre-C11 compat checks
# are irrelevant). Together with the GCC build above and `make analyze` this is the strictest gate: `make strict`.
CLANG ?= clang
CLANG_STRICT := -std=c11 -Weverything -Werror -Wno-unsafe-buffer-usage -Wno-padded -Wno-declaration-after-statement \
                -Wno-pre-c11-compat -Wno-c++98-compat -Wno-covered-switch-default -Wno-switch-default \
                -Wno-disabled-macro-expansion -Wno-unknown-warning-option
strict-clang: $(GEN)/bundled.c
	@for f in $(ALLSRC); do \
	  echo "clang $$f"; \
	  $(CLANG) $(CLANG_STRICT) $(INC) -DNDEBUG_SP -fsyntax-only $$f || exit 1; \
	done
strict: all debug analyze strict-clang
.PHONY: strict-clang strict

# shared libraries used by the ffi tests (the C++ one only when a C++ compiler exists)
FFI_LIBS := $(BUILD)/libctest.so $(if $(shell command -v c++ 2>/dev/null),$(BUILD)/libcxxtest.so)
$(BUILD)/libctest.so: tests/ffi/ctest.c
	@mkdir -p $(BUILD)
	$(CC) -std=c11 -O2 -Wall -Wextra -Werror -shared -fPIC -o $@ $<
$(BUILD)/libcxxtest.so: tests/ffi/cxxtest.cpp
	@mkdir -p $(BUILD)
	c++ -std=c++17 -O2 -Wall -Wextra -Werror -shared -fPIC -o $@ $<

test: $(BUILD)/sprint $(FFI_LIBS) test-trace-snapshot test-gc-stress test-gc-stack-growth test-gc-stats
	@SPRINT=$(BUILD)/sprint sh tests/run_tests.sh

test-san: $(BUILD)/sprint-san $(FFI_LIBS) test-trace-snapshot-san test-gc-stress-san test-gc-stack-growth-san test-gc-stats-san
	@SPRINT=$(BUILD)/sprint-san sh tests/run_tests.sh

# Force the mark stack to one entry so the allocation-free heap-rescan fallback is exercised.
test-gc-stress: $(BUILD)/sprint
	@SPRINT_GC_STRESS=1 SPRINT_GC_MARK_LIMIT=1 $(BUILD)/sprint run tests/cases/lang/gc.sp > $(BUILD)/gc-stress.out
	@cmp $(BUILD)/gc-stress.out tests/cases/lang/gc.out && echo 'gc: stress + one-slot mark fallback + cyclic graph + stats verified'
	@SPRINT_GC_STRESS=1 $(BUILD)/sprint run tests/cases/lang/ctor_fast.sp > $(BUILD)/ctor-stress.out
	@cmp $(BUILD)/ctor-stress.out tests/cases/lang/ctor_fast.out && echo 'gc: constructors (including failed ones) survive a collection at every allocation'

test-gc-stress-san: $(BUILD)/sprint-san
	@SPRINT_GC_STRESS=1 SPRINT_GC_MARK_LIMIT=1 ASAN_OPTIONS=detect_leaks=1 $(BUILD)/sprint-san run tests/cases/lang/gc.sp > $(BUILD)/gc-stress-san.out
	@cmp $(BUILD)/gc-stress-san.out tests/cases/lang/gc.out && echo 'gc-san: stress + one-slot mark fallback + cyclic graph + stats verified'

test-gc-stack-growth: $(BUILD)/sprint
	@$(BUILD)/sprint run tests/cases/lang/gc.sp > $(BUILD)/gc-growth.out
	@cmp $(BUILD)/gc-growth.out tests/cases/lang/gc.out && echo 'gc: dynamic mark-stack growth (>1024 references) verified'

test-gc-stack-growth-san: $(BUILD)/sprint-san
	@ASAN_OPTIONS=detect_leaks=1 $(BUILD)/sprint-san run tests/cases/lang/gc.sp > $(BUILD)/gc-growth-san.out
	@cmp $(BUILD)/gc-growth-san.out tests/cases/lang/gc.out && echo 'gc-san: dynamic mark-stack growth (>1024 references) verified'

test-gc-stats: $(BUILD)/sprint
	@$(BUILD)/sprint run tests/runtime/gc_stats.sp > $(BUILD)/gc-stats.out
	@cmp $(BUILD)/gc-stats.out tests/runtime/gc_stats.out && echo 'gc: live_objects increases on allocation and decreases after collection'

test-gc-stats-san: $(BUILD)/sprint-san
	@ASAN_OPTIONS=detect_leaks=1 $(BUILD)/sprint-san run tests/runtime/gc_stats.sp > $(BUILD)/gc-stats-san.out
	@cmp $(BUILD)/gc-stats-san.out tests/runtime/gc_stats.out && echo 'gc-san: live_objects accounting verified'

# C embedding API: build the host programs against the library (release and
# ASan/UBSan builds) and run them.
$(BUILD)/libsprint-san.a: $(filter-out $(BUILD)/dbg/cli/%,$(DBG_OBJ))
	rm -f $@
	ar rcs $@ $^

test-embed: $(BUILD)/libsprint.a $(BUILD)/libsprint-san.a
	$(CC) $(STD) $(WARN) $(HARDEN) -O2 $(INC) -o $(BUILD)/embed_test tests/embed/embed_test.c $(BUILD)/libsprint.a -lm -ldl
	$(CC) $(STD) $(WARN) $(HARDEN) -O0 -g $(INC) -fsanitize=address,undefined -fno-sanitize-recover=undefined -o $(BUILD)/embed_test-san tests/embed/embed_test.c $(BUILD)/libsprint-san.a -lm -ldl -fsanitize=address,undefined
	$(BUILD)/embed_test
	$(BUILD)/embed_test-san
	$(CC) $(STD) $(WARN) $(HARDEN) -O2 $(INC) -o $(BUILD)/embed_demo examples/embed/host.c $(BUILD)/libsprint.a -lm -ldl
	$(BUILD)/embed_demo > $(BUILD)/embed_demo.out
	@cmp $(BUILD)/embed_demo.out tests/embed/host_demo.out && echo "embed demo ok"

clean:
	rm -rf $(BUILD)

-include $(REL_OBJ:.o=.d) $(DBG_OBJ:.o=.d)
include os/os.mk

# Deliberately not enabled:
#  -Wunsuffixed-float-constants, -Wdeclaration-after-statement, -Wtraditional-conversion   style checks, not defects
#  -Wpadded            SpValue's explicit padding is part of the ABI (SPEC 6.2)
#  -Wtraditional, -Wsystem-headers   obsolete / noise from libc
#  -fanalyzer in the normal build    slow; run `make analyze` instead
#  -Wstrict-overflow                 deprecated in favour of -fno-strict-overflow (enabled above)
#  -Winline                          noise; inlining is the optimiser's business
# Exact floating-point comparison is required by the language (SPEC 7.5/7.6), so
# -Wfloat-equal stays on and each intentional site carries a local, commented pragma.

bench: $(BUILD)/sprint
	tools/bench/run.sh $(BUILD)/sprint

# ---- Copy-and-patch JIT: regenerate the committed stencil table (needs gcc + the assembler; not part of normal builds)
jit-regen: tools/jitgen.c tools/jitlayout.c src/runtime/jit/stencils.S
	$(CC) -O1 $(INC) -o $(GEN)/jitlayout tools/jitlayout.c
	$(GEN)/jitlayout > src/runtime/jit/layout.h
	$(CC) -O1 -o $(GEN)/jitgen tools/jitgen.c
	$(CC) -O2 -c -x assembler-with-cpp -Isrc/runtime/jit -o $(GEN)/stencils.o src/runtime/jit/stencils.S
	$(GEN)/jitgen $(GEN)/stencils.o > src/runtime/jit/stencils.h
.PHONY: jit-regen

# Whole suite with the JIT compiling every loop at its first back edge (the output must equal the interpreter's).
test-jit: $(BUILD)/sprint $(FFI_LIBS) test-trace-snapshot
	@SPRINT_JIT_THRESHOLD=1 SPRINT=$(BUILD)/sprint sh tests/run_tests.sh
.PHONY: test-jit

# TraceJIT records a complete loop iteration before compiling the hot trace.
test-trace-jit: $(BUILD)/sprint $(FFI_LIBS) test-trace-snapshot test-trace-snapshot-budget test-trace-side test-trace-side-cache
	@SPRINT_JIT_THRESHOLD=2 SPRINT_TRACE_JIT=1 SPRINT_TRACE_JIT_F64=1 SPRINT=$(BUILD)/sprint sh tests/run_tests.sh
.PHONY: test-trace-jit

# Differential fuzz of the TraceJIT path builder (random branchy int/float loops under four JIT configurations)
fuzz-trace: $(BUILD)/sprint
	python3 tools/jitfuzz_trace.py $(BUILD)/sprint 300 1
	python3 tools/jitfuzz_trace.py $(BUILD)/sprint 300 2
.PHONY: fuzz-trace

# Run the in-file TraceIR verifier/optimizer invariant suite under the strict diagnostics.
test-trace-ir: | $(BUILD)
	$(CC) $(STD) $(WARN) $(HARDEN) -O2 $(INC) -DSPRINT_TRACE_IR_TEST -o $(BUILD)/trace-ir-test src/runtime/trace_ir.c
	$(BUILD)/trace-ir-test
.PHONY: test-trace-ir

# Snapshot map/token/restore invariants used by TraceJIT side exits.
test-trace-snapshot: | $(BUILD)
	$(CC) $(STD) $(WARN) $(HARDEN) -O2 $(INC) -o $(BUILD)/snapshot-test tests/runtime/snapshot_test.c src/runtime/jit/snapshot.c src/runtime/trace_ir.c
	$(BUILD)/snapshot-test
.PHONY: test-trace-snapshot

test-trace-snapshot-san: | $(BUILD)
	$(CC) $(STD) $(WARN) $(HARDEN) -O0 -g -fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer $(INC) -o $(BUILD)/snapshot-test-san tests/runtime/snapshot_test.c src/runtime/jit/snapshot.c src/runtime/trace_ir.c -fsanitize=address,undefined
	$(BUILD)/snapshot-test-san
.PHONY: test-trace-snapshot-san

test-trace-side: $(BUILD)/sprint
	# Keep the region JIT cold so this test exercises TraceJIT linking and Side Trace dispatch.
	@SPRINT_JIT_THRESHOLD=10000 SPRINT_TRACE_JIT=1 SPRINT_TRACE_JIT_F64=1 SPRINT_TRACE_JIT_DEBUG=1 $(BUILD)/sprint run tests/cases/jit/jit_trace_side.sp > $(BUILD)/trace-side.log 2>&1
	@grep -Eq 'trace-jit: side-record-request polymorphic_loop@' $(BUILD)/trace-side.log
	@grep -q 'trace-jit: native-link linked_side@32 -> @69' $(BUILD)/trace-side.log
	@grep -q 'trace-jit: result slot=1 kind=2 owner=linked_side@69' $(BUILD)/trace-side.log
	@grep -q 'trace-jit: side-record-request linked_side@69' $(BUILD)/trace-side.log
	@test $$(grep -c 'trace-jit: side-compiled' $(BUILD)/trace-side.log) -ge 3
	@grep -q 'trace-jit: side-hit linked_side@69' $(BUILD)/trace-side.log
	@grep -q 'trace-jit: side-record-request ref_loop@' $(BUILD)/trace-side.log
	@test $$(grep -c 'trace-jit: side-compiled ref_loop@' $(BUILD)/trace-side.log) -eq 4
	@grep -q 'trace-jit: side-compiled ref_loop@.*depth=1 ' $(BUILD)/trace-side.log
	@grep -q 'trace-jit: side-compiled ref_loop@.*depth=2 ' $(BUILD)/trace-side.log
	@test $$(grep -c 'trace-jit: side-compiled ref_loop@.*depth=3 ' $(BUILD)/trace-side.log) -eq 2
	@grep -q 'trace-jit: side-record-request ref_loop@.*depth=2 ' $(BUILD)/trace-side.log
	@grep -q 'trace-jit: side-hit ref_loop@' $(BUILD)/trace-side.log
	@tail -n 18 $(BUILD)/trace-side.log > $(BUILD)/trace-side.out
	@cmp $(BUILD)/trace-side.out tests/cases/jit/jit_trace_side.out && echo 'trace-side: Root + Side-of-Side depth 1/2/3 + bounded branching + linked MISS verified'
	@SPRINT_GC_STRESS=1 SPRINT_JIT_THRESHOLD=10000 SPRINT_TRACE_JIT=1 SPRINT_TRACE_JIT_F64=1 $(BUILD)/sprint run tests/cases/jit/jit_trace_side.sp > $(BUILD)/trace-side-gc.log 2>&1
	@tail -n 18 $(BUILD)/trace-side-gc.log > $(BUILD)/trace-side-gc.out
	@cmp $(BUILD)/trace-side-gc.out tests/cases/jit/jit_trace_side.out && echo 'trace-side: reference values survive GC-stress allocations after native restore'
.PHONY: test-trace-side

# Stress root/side cache admission, parent-child eviction and re-entry across 70 loop sites.
test-trace-side-cache: $(BUILD)/sprint
	@SPRINT_JIT_THRESHOLD=10000 SPRINT_TRACE_JIT=1 SPRINT_TRACE_JIT_F64=1 SPRINT_TRACE_JIT_DEBUG=1 $(BUILD)/sprint run tests/cases/jit/jit_trace_cache.sp > $(BUILD)/trace-side-cache.log 2>&1
	@grep -q 'trace-jit: side-record-request many@' $(BUILD)/trace-side-cache.log
	@test $$(grep -c 'trace-jit: side-compiled many@' $(BUILD)/trace-side-cache.log) -ge 20
	@grep -q 'trace-jit: side-hit many@' $(BUILD)/trace-side-cache.log
	@! grep -q 'trace-jit: rejected many@' $(BUILD)/trace-side-cache.log
	@grep -Eq 'cache=64/[0-9]+B' $(BUILD)/trace-side-cache.log
	@tail -n 3 $(BUILD)/trace-side-cache.log > $(BUILD)/trace-side-cache.out
	@cmp $(BUILD)/trace-side-cache.out tests/cases/jit/jit_trace_cache.out && echo 'trace-side-cache: 70 roots + side variants + bounded LRU verified'
.PHONY: test-trace-side-cache

test-trace-snapshot-budget: $(BUILD)/sprint
	@set +e; SPRINT_JIT_THRESHOLD=2 SPRINT_TRACE_JIT=1 SPRINT_TRACE_JIT_F64=1 SPRINT_TRACE_JIT_DEBUG=1 $(BUILD)/sprint run --max-instr 2000 tests/runtime/snapshot_budget.sp > $(BUILD)/snapshot-budget.log 2>&1; status=$$?; set -e; \
	  test $$status -eq 124 && grep -q 'snapshot slot=.*kind=3' $(BUILD)/snapshot-budget.log && \
	  grep -q 'TimeoutError: instruction limit exceeded' $(BUILD)/snapshot-budget.log && \
	  echo "snapshot-budget: budget exit restored and limit error preserved"
.PHONY: test-trace-snapshot-budget
