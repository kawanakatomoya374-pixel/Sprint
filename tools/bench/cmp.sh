#!/bin/sh
# usage: tools/bench/cmp.sh [sprint] -- wall time per benchmark (best of 3): Sprint with the JIT, Sprint without it
# (SPRINT_JIT=0), Lua 5.4, LuaJIT, V8 (node) and C (gcc -O3, c/NAME.c). Missing runtimes show 0. The last columns are
# Sprint(JIT) / LuaJIT, / V8 and / C (smaller is faster). A benchmark is included when it has NAME.sp and lua/NAME.lua;
# luajit uses lua/NAME.luajit.lua when present, V8 runs js/NAME.js, C builds c/NAME.c into $TMPDIR. The last line gives
# process start-up of each runtime (an empty program), which is part of every figure above.
# ONLY="a b" restricts the run to those benchmarks; NOJIT=0 skips the no-JIT column (shown as 0).
S=${1:-build/sprint}; D=$(dirname "$0"); T=${TMPDIR:-/tmp}/sprint-bench-c; mkdir -p "$T"
best() { b=999; for i in 1 2 3; do s=$(date +%s.%N); "$@" >/dev/null 2>&1; e=$(date +%s.%N); t=$(echo "$e - $s" | bc); b=$(echo "if ($t < $b) $t else $b" | bc); done; echo $b; }
ratio() { if [ "$(echo "$2 > 0" | bc)" = 1 ]; then echo "$1 / $2" | bc -l; else echo 0; fi; }
HAVE_LJ=0; command -v luajit >/dev/null 2>&1 && HAVE_LJ=1
NODE=$(command -v node || command -v nodejs || true); HAVE_V8=0; [ -n "$NODE" ] && HAVE_V8=1
LUA=$(command -v lua5.4 || command -v lua)
printf '%-9s %6s %6s %6s %6s %6s %6s %7s %7s %7s\n' bench jit nojit lua luajit v8 c-O3 jit/lj jit/v8 jit/c
for l in "$D"/lua/*.lua; do n=$(basename "$l" .lua); case $n in *.luajit) continue;; esac; [ -f "$D/$n.sp" ] || continue
  if [ -n "$ONLY" ]; then case " $ONLY " in *" $n "*) ;; *) continue;; esac; fi
  a=$(best "$S" run "$D/$n.sp"); a0=0; [ "${NOJIT:-1}" = 0 ] || a0=$(SPRINT_JIT=0 best "$S" run "$D/$n.sp"); b=0; [ -n "$LUA" ] && b=$(best "$LUA" "$l")
  j=0; if [ $HAVE_LJ = 1 ]; then lj="$D/lua/$n.luajit.lua"; [ -f "$lj" ] || lj="$l"; j=$(best luajit "$lj"); fi
  v=0; if [ $HAVE_V8 = 1 ] && [ -f "$D/js/$n.js" ]; then v=$(best "$NODE" "$D/js/$n.js"); fi
  c=0; if [ -f "$D/c/$n.c" ] && ${CC:-gcc} -O3 -o "$T/$n" "$D/c/$n.c" -lm 2>/dev/null; then c=$(best "$T/$n"); fi
  printf '%-9s %6.2f %6.2f %6.2f %6.2f %6.2f %6.2f %7.2f %7.2f %7.2f\n' "$n" "$a" "$a0" "$b" "$j" "$v" "$c" \
    "$(ratio "$a" "$j")" "$(ratio "$a" "$v")" "$(ratio "$a" "$c")"; done
echo '' > "$T/e.sp"; echo '' > "$T/e.lua"; echo '' > "$T/e.js"; echo 'int main(void){return 0;}' > "$T/e.c"; ${CC:-gcc} -O3 -o "$T/e" "$T/e.c"
printf 'start-up (empty program): sprint %.3f  lua %.3f  c %.3f' "$(best "$S" run "$T/e.sp")" "$(best "$LUA" "$T/e.lua")" "$(best "$T/e")"
[ $HAVE_LJ = 1 ] && printf '  luajit %.3f' "$(best luajit "$T/e.lua")"
[ $HAVE_V8 = 1 ] && printf '  v8 %.3f' "$(best "$NODE" "$T/e.js")"
echo
