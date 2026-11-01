#!/bin/sh
# usage: tools/bench/trace_cmp.sh [sprint] [bench...] -- wall time (best of 5) with the TraceJIT on (the default) and off
# (SPRINT_TRACE_JIT=0) for each benchmark, and the on/off ratio. A ratio above 1.05 is flagged: the TraceJIT must never make
# a program slower than the region JIT alone (docs/design/tiered-jit.md, policy). Benchmarks needing --allow-ffi are skipped.
S=${1:-build/sprint}; [ $# -gt 0 ] && shift; D=$(dirname "$0")
LIST=${*:-$(cd "$D" && ls *.sp | sed 's/\.sp$//')}
best() { b=999; for i in 1 2 3 4 5; do s=$(date +%s.%N); "$@" >/dev/null 2>&1; e=$(date +%s.%N); t=$(echo "$e - $s" | bc); b=$(echo "if ($t < $b) $t else $b" | bc); done; echo $b; }
printf '%-12s %8s %8s %7s\n' bench trace-on trace-off ratio
for n in $LIST; do
  case $n in ffi_*|gui*|natcall|gc_long) continue;; esac
  on=$(best "$S" run "$D/$n.sp"); off=$(SPRINT_TRACE_JIT=0 best "$S" run "$D/$n.sp")
  r=$(echo "$on / $off" | bc -l); flag=""; [ "$(echo "$r > 1.05" | bc)" = 1 ] && flag="  <-- slower with trace"
  printf '%-12s %8.3f %8.3f %7.2f%s\n' "$n" "$on" "$off" "$r" "$flag"
done
