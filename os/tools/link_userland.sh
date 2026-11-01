#!/bin/sh
# usage: link_userland.sh CC OUT.elf OBJ...
# Links the ring-3 program as a static-PIE and checks the result: ET_DYN, no PT_INTERP, no DT_NEEDED. musl-tools releases whose
# musl-gcc.specs do not know -static-pie (they silently produce a dynamically linked PIE that cannot run under the Sprint kernel's
# ELF loader) are handled by linking explicitly against rcrt1.o, which relocates the program itself.
# SPRINT_FORCE_RCRT=1 forces the explicit path (used to test it); MUSL_LIB=DIR names the musl library directory.
set -e
cc=$1; out=$2; shift 2

is_static_pie() {
    readelf -h "$1" | grep -q 'Type:[[:space:]]*DYN' || return 1
    readelf -lW "$1" | grep -q INTERP && return 1
    readelf -d "$1" 2>/dev/null | grep -q NEEDED && return 1
    return 0
}

if [ -z "$SPRINT_FORCE_RCRT" ]; then
    "$cc" -static-pie -o "$out" "$@" -lm
    is_static_pie "$out" && exit 0
    echo "link_userland: '$cc -static-pie' did not produce a static-PIE (old musl-gcc.specs?); linking against rcrt1.o explicitly" >&2
fi

lib=
for d in "$MUSL_LIB" /usr/lib/x86_64-linux-musl /usr/lib/musl/lib /usr/local/musl/lib "$(dirname "$(dirname "$(command -v "$cc")")")/lib"; do
    [ -n "$d" ] && [ -f "$d/rcrt1.o" ] && { lib=$d; break; }
done
if [ -z "$lib" ]; then
    echo "link_userland: rcrt1.o not found (musl >= 1.1.20 provides it); set MUSL_LIB=<dir containing rcrt1.o>" >&2
    exit 1
fi
crtbegin=$("$cc" -print-file-name=crtbeginS.o)
crtend=$("$cc" -print-file-name=crtendS.o)
"$cc" -nostartfiles -Wl,-static -Wl,-pie -Wl,--no-dynamic-linker -Wl,-z,text -o "$out" \
    "$lib/rcrt1.o" "$lib/crti.o" "$crtbegin" "$@" -lm "$crtend" "$lib/crtn.o"
is_static_pie "$out" || { echo "link_userland: $out is still not a static-PIE" >&2; exit 1; }
