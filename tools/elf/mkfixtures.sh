#!/bin/sh
# Rebuilds tests/data/elf/*.so and prog from the C files next to this script (needs gcc and binutils).
set -e
cd "$(dirname "$0")"
out=../../tests/data/elf
mkdir -p $out
F="-nostdlib -fPIC -O1 -fno-asynchronous-unwind-tables -fno-ident -fno-stack-protector -Wl,--hash-style=both -Wl,-z,max-page-size=4096 -Wl,-z,separate-code -Wl,--build-id=none -s"
gcc -shared $F -ftls-model=initial-exec -Wl,-soname,libb.so libb.c -o $out/libb.so
gcc -shared $F -Wl,-soname,liba.so -Wl,-rpath,'$ORIGIN' liba.c -o $out/liba.so -L$out -l:libb.so
gcc -shared $F -Wl,-soname,libv.so -Wl,--version-script=libv.map libv.c -o $out/libv.so
gcc -shared $F -Wl,-soname,libr.so -Wl,-z,pack-relative-relocs libr.c -o $out/libr.so || echo "no RELR support: skipped libr.so"
gcc -pie -fPIE $F -Wl,-e,_start -Wl,--no-dynamic-linker -Wl,--export-dynamic -Wl,-rpath,'$ORIGIN' main.c -o $out/prog -L$out -l:liba.so -l:libb.so
gcc -shared $F -Wl,-soname,libg.so -Wl,--hash-style=gnu libb.c -o $out/libg.so -ftls-model=initial-exec
gcc -shared $F -Wl,-soname,libs.so -Wl,--hash-style=sysv libb.c -o $out/libs.so -ftls-model=initial-exec
