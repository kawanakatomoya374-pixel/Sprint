#!/bin/sh
# usage: tools/bench/cmp.sh [sprint] -- wall time per benchmark (best of 3): Sprint with the JIT, Sprint without it
# (SPRINT_JIT=0), Lua 5.4 and, when installed, LuaJIT and V8 (node). The last two columns are Sprint(JIT) / LuaJIT and
# Sprint(JIT) / V8 (smaller is faster). A benchmark is included when it has both NAME.sp and lua/NAME.lua; luajit uses
# lua/NAME.luajit.lua when it exists, and V8 runs js/NAME.js. The line after the table gives the process start-up of each
# runtime (an empty program), which is part of every figure above.
S=${1:-build/sprint}; D=$(dirname "$0")
best() { b=999; for i in 1 2 3; do s=$(date +%s.%N); "$@" >/dev/null 2>&1; e=$(date +%s.%N); t=$(echo "$e - $s" | bc); b=$(echo "if ($t < $b) $t else $b" | bc); done; echo $b; }
HAVE_LJ=0; command -v luajit >/dev/null 2>&1 && HAVE_LJ=1
NODE=$(command -v node || command -v nodejs || true); HAVE_V8=0; [ -n "$NODE" ] && HAVE_V8=1
printf '%-9s %7s %7s %7s %7s %7s %8s %8s\n' bench jit nojit lua5.4 luajit v8 jit/lj jit/v8
for l in "$D"/lua/*.lua; do n=$(basename "$l" .lua); [ -f "$D/$n.sp" ] || continue
  a=$(best "$S" run "$D/$n.sp"); a0=$(SPRINT_JIT=0 best "$S" run "$D/$n.sp"); b=$(best lua5.4 "$l")
  if [ $HAVE_LJ = 1 ]; then lj="$D/lua/$n.luajit.lua"; [ -f "$lj" ] || lj="$l"; j=$(best luajit "$lj"); r=$(echo "$a / $j" | bc -l); else j=0; r=0; fi
  if [ $HAVE_V8 = 1 ] && [ -f "$D/js/$n.js" ]; then v=$(best "$NODE" "$D/js/$n.js"); rv=$(echo "$a / $v" | bc -l); else v=0; rv=0; fi
  printf '%-9s %7.2f %7.2f %7.2f %7.2f %7.2f %8.2f %8.2f\n' "$n" "$a" "$a0" "$b" "$j" "$v" "$r" "$rv"; done
echo '' > /tmp/sprint-empty.sp; echo '' > /tmp/sprint-empty.lua; echo '' > /tmp/sprint-empty.js
printf 'start-up (empty program): sprint %.3f  lua5.4 %.3f' "$(best "$S" run /tmp/sprint-empty.sp)" "$(best lua5.4 /tmp/sprint-empty.lua)"
[ $HAVE_LJ = 1 ] && printf '  luajit %.3f' "$(best luajit /tmp/sprint-empty.lua)"
[ $HAVE_V8 = 1 ] && printf '  v8 %.3f' "$(best "$NODE" /tmp/sprint-empty.js)"
echo
