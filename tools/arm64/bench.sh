#!/bin/sh
# Runs benchmarks with the AArch64 build under qemu-user: output equality with the x86-64 build, and time with / without the JIT.
# usage: SPRINT_A64=build/sprint-a64 tools/arm64/bench.sh name...   (x86-64 build/sprint must exist)
for b in "$@"; do
    f=tools/bench/$b.sp; [ -f "$f" ] || continue
    want=$(build/sprint run --allow-ffi "$f" 2>/dev/null | md5sum | cut -d' ' -f1)
    s=$(date +%s.%N); got=$(timeout 120 tools/arm64/sprint-a64 run --allow-ffi "$f" 2>/dev/null | md5sum | cut -d' ' -f1); e=$(date +%s.%N)
    s2=$(date +%s.%N); timeout 120 tools/arm64/sprint-a64 run --no-jit --allow-ffi "$f" >/dev/null 2>&1; e2=$(date +%s.%N)
    ok=ok; [ "$want" = "$got" ] || ok=WRONG
    printf "%-12s jit %6.2fs  nojit %6.2fs  x%.1f  %s\n" "$b" "$(echo "$e - $s" | bc)" "$(echo "$e2 - $s2" | bc)" "$(echo "($e2 - $s2) / ($e - $s)" | bc -l)" "$ok"
done
