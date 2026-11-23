#!/bin/sh
# Assembles the Sprint-assembler version of smp_user's assembly (smp_user.sp), the same source with NASM, and the original GNU as
# source (smp_user_ref.S) and checks that all three give the same bytes. Run from the repository root after `make`.
set -e
t=$(mktemp -d)
build/sprint run --allow-write="$t" os/asm/smp_user.sp "$t/sprint.bin" "$t/src.asm"
gcc -c os/asm/smp_user_ref.S -o "$t/ref.o"
objcopy -O binary -j .text "$t/ref.o" "$t/gnu.bin"
nasm -f bin "$t/src.asm" -o "$t/nasm.bin"
cmp "$t/sprint.bin" "$t/gnu.bin" && echo "Sprint assembler == GNU as ($(wc -c < "$t/gnu.bin") bytes)"
cmp "$t/nasm.bin" "$t/gnu.bin" && echo "NASM == GNU as"
rm -rf "$t"
