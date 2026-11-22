#!/bin/sh
# Runs the JIT and language tests with the AArch64 build under qemu-user (SPRINT_A64=path). libm differs slightly between targets, so
# tests/cases/lang/mathfast.sp is skipped.
pass=0; fail=0
for f in tests/cases/jit/*.sp tests/cases/lang/*.sp tests/cases/syntax/*.sp tests/cases/class/*.sp; do
    o=${f%.sp}.out; [ -f "$o" ] || continue
    case $f in *mathfast*) continue ;; esac
    rc_exp=0; [ -f "${f%.sp}.rc" ] && rc_exp=$(cat "${f%.sp}.rc")
    args=""; [ -f "${f%.sp}.args" ] && args=$(cat "${f%.sp}.args")
    for t in 1 40; do
        out=$(SPRINT_JIT_THRESHOLD=$t timeout 300 tools/arm64/sprint-a64 run --deterministic $args "$f" 2>/dev/null); rc=$?
        if [ "$out" = "$(cat "$o")" ] && [ "$rc" = "$rc_exp" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $f (threshold $t, rc=$rc)"; fi
    done
done
# ffi tests that need only libc (not the x86-64 build/libctest.so)
for f in tests/ffi/ffi_union_bits tests/ffi/ffi_global tests/ffi/ffi_callback_libc tests/cases/stdlib/asm_basic; do
    out=$(timeout 300 tools/arm64/sprint-a64 run --allow-ffi "$f.sp" 2>/dev/null)
    if [ "$out" = "$(cat "$f.out")" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $f"; fi
done
echo "arm64: passed $pass, failed $fail"
[ "$fail" = 0 ]
