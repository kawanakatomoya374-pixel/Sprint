#!/bin/sh
# Compares stdout and exit code only (diagnostic text is not part of conformance).
SPRINT=${SPRINT:-build/sprint}
pass=0; fail=0
for f in tests/cases/*/*.sp; do
    b=${f%.sp}
    exp_rc=0; [ -f "$b.rc" ] && exp_rc=$(cat "$b.rc")
    # A failed compile releases everything through the front-end cleanup stack,
    # so LeakSanitizer stays on for the diagnostic cases too.
    leaks=1
    args=""; [ -f "$b.args" ] && args=$(cat "$b.args")
    out=$(ASAN_OPTIONS=detect_leaks=$leaks "$SPRINT" run --deterministic $args "$f" 2>/dev/null); rc=$?
    if [ "$out" = "$(cat "$b.out")" ] && [ "$rc" = "$exp_rc" ]; then pass=$((pass+1))
    else fail=$((fail+1)); echo "FAIL $f (rc=$rc, expected $exp_rc)"; fi
done
for f in examples/basics/*.sp examples/gfx/*.sp examples/gui/*.sp examples/os/*.sp; do
    b=${f%.sp}; exp="tests/examples/$(basename "$b").out"
    out=$("$SPRINT" run --deterministic --allow-write=build "$f" 2>/dev/null); rc=$?
    if [ "$out" = "$(cat "$exp")" ] && [ "$rc" = 0 ]; then pass=$((pass+1))
    else fail=$((fail+1)); echo "FAIL $f (rc=$rc)"; fi
done
for d in tests/mods/*/; do
    d=${d%/}
    f=$d/main.sp; [ -f "$f" ] || f=$d/src/main.sp
    exp_rc=0; [ -f "$d/main.rc" ] && exp_rc=$(cat "$d/main.rc")
    leaks=1
    out=$(ASAN_OPTIONS=detect_leaks=$leaks "$SPRINT" run --deterministic "$f" 2>/dev/null); rc=$?
    if [ "$out" = "$(cat "$d/main.out")" ] && [ "$rc" = "$exp_rc" ]; then pass=$((pass+1))
    else fail=$((fail+1)); echo "FAIL $d (rc=$rc, expected $exp_rc)"; fi
done
# source tools: fmt output (and idempotence), lint output and exit status
for f in tests/fmt/*.sp; do
    b=${f%.sp}
    out=$("$SPRINT" fmt "$f" 2>/dev/null); rc=$?
    printf '%s\n' "$out" > build/fmt-pass1.sp
    out2=$("$SPRINT" fmt build/fmt-pass1.sp 2>/dev/null)
    if [ "$out" = "$(cat "$b.out")" ] && [ "$rc" = 0 ] && [ "$out" = "$out2" ]; then pass=$((pass+1))
    else fail=$((fail+1)); echo "FAIL fmt $f (rc=$rc)"; fi
done
for f in tests/lint/*.sp; do
    b=${f%.sp}
    exp_rc=1; [ -s "$b.out" ] || exp_rc=0
    out=$("$SPRINT" lint "$f" 2>/dev/null); rc=$?
    if [ "$out" = "$(cat "$b.out")" ] && [ "$rc" = "$exp_rc" ]; then pass=$((pass+1))
    else fail=$((fail+1)); echo "FAIL lint $f (rc=$rc)"; fi
done
# REPL: scripted sessions on stdin (stdout and exit code compared)
for f in tests/repl/*.in; do
    b=${f%.in}
    exp_rc=0; [ -f "$b.rc" ] && exp_rc=$(cat "$b.rc")
    out=$(ASAN_OPTIONS=detect_leaks=1 "$SPRINT" repl --deterministic < "$f" 2>/dev/null); rc=$?
    if [ "$out" = "$(cat "$b.out")" ] && [ "$rc" = "$exp_rc" ]; then pass=$((pass+1))
    else fail=$((fail+1)); echo "FAIL repl $f (rc=$rc, expected $exp_rc)"; fi
done
# program images: compile, run the image, compare with the source run; corrupted images are rejected
img=build/test-image.spc
check_img() { # name, source, expected-out-file, expected-rc
    "$SPRINT" compile -o "$img" "$2" 2>/dev/null || { fail=$((fail+1)); echo "FAIL compile $2"; return; }
    out=$("$SPRINT" exec --deterministic "$img" 2>/dev/null); rc=$?
    if [ "$out" = "$(cat "$3")" ] && [ "$rc" = "$4" ]; then pass=$((pass+1))
    else fail=$((fail+1)); echo "FAIL image $1 (rc=$rc, expected $4)"; fi
}
for f in tests/cases/*/*.sp; do
    b=${f%.sp}
    [ -f "$b.args" ] && continue
    exp_rc=0; [ -f "$b.rc" ] && exp_rc=$(cat "$b.rc")
    [ "$exp_rc" = 12 ] || [ "$exp_rc" = 4 ] && continue
    check_img "$f" "$f" "$b.out" "$exp_rc"
done
check_img tests/mods/basic tests/mods/basic/main.sp tests/mods/basic/main.out 0
"$SPRINT" compile -o "$img" tests/cases/class/class.sp
size=$(wc -c < "$img")
for variant in flip trunc extra; do
    case $variant in
        flip)  { head -c 100 "$img"; printf 'X'; tail -c +102 "$img"; } > build/test-bad.spc ;;
        trunc) head -c $((size - 7)) "$img" > build/test-bad.spc ;;
        extra) { cat "$img"; printf 'Z'; } > build/test-bad.spc ;;
    esac
    out=$("$SPRINT" run build/test-bad.spc 2>/dev/null); rc=$?
    if [ "$rc" = 13 ] && [ -z "$out" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL bad image ($variant) rc=$rc"; fi
done
# ffi: real shared libraries (build/libctest.so, and build/libcxxtest.so when a C++ compiler exists)
for f in tests/ffi/*.sp; do
    b=${f%.sp}
    case "$f" in *ffi_cxx.sp) [ -f build/libcxxtest.so ] || continue ;; esac
    [ -f build/libctest.so ] || { fail=$((fail+1)); echo "FAIL $f (build/libctest.so missing)"; continue; }
    out=$(ASAN_OPTIONS=detect_leaks=0 "$SPRINT" run --allow-ffi "$f" 2>/dev/null); rc=$?
    if [ "$out" = "$(cat "$b.out")" ] && [ "$rc" = 0 ]; then pass=$((pass+1))
    else fail=$((fail+1)); echo "FAIL $f (rc=$rc)"; fi
    q=$(ASAN_OPTIONS=detect_leaks=0 "$SPRINT" run --allow-ffi --no-quicken "$f" 2>/dev/null)
    if [ "$q" = "$out" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL quicken-diff $f"; fi
done
# without --allow-ffi (or with --deterministic) every ffi call is refused
out=$("$SPRINT" run --deterministic --allow-ffi tests/cases/stdlib/ffi_denied.sp 2>/dev/null)
if [ "$out" = "$(cat tests/cases/stdlib/ffi_denied.out)" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL ffi deterministic denial"; fi
# differential: fused opcodes must not change any observable behaviour
for f in tests/cases/*/*.sp examples/basics/*.sp examples/gfx/*.sp examples/gui/*.sp examples/os/*.sp; do
    b=${f%.sp}; args=""; [ -f "$b.args" ] && args=$(cat "$b.args")
    a=$(ASAN_OPTIONS=detect_leaks=0 "$SPRINT" run --deterministic $args "$f" 2>&1); ra=$?
    n=$(ASAN_OPTIONS=detect_leaks=0 "$SPRINT" run --deterministic --no-quicken $args "$f" 2>&1); rn=$?
    if [ "$a" = "$n" ] && [ "$ra" = "$rn" ]; then pass=$((pass+1))
    else fail=$((fail+1)); echo "FAIL quicken-diff $f"; fi
done
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
