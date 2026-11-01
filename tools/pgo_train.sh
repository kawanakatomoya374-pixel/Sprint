#!/bin/sh
# usage: tools/pgo_train.sh instrumented-sprint -- run a representative workload so the compiler records branch profiles:
# every micro benchmark with the JIT on and off (the interpreter and the JIT runtime both matter) and the language tests.
S=${1:-build/sprint}; D=$(dirname "$0")
for f in "$D"/bench/*.sp; do
  case $(basename "$f") in ffi_*|gui*|natcall|gc_long) continue;; esac
  for j in 0 1; do SPRINT_JIT=$j "$S" run "$f" >/dev/null 2>&1; done
done
for f in "$D"/../tests/cases/lang/*.sp "$D"/../tests/cases/class/class.sp "$D"/../tests/cases/stdlib/json.sp; do
  "$S" run --deterministic "$f" >/dev/null 2>&1
  SPRINT_JIT=0 "$S" run --deterministic "$f" >/dev/null 2>&1
done
exit 0
