#!/bin/sh
# Boots the image that examples/boot/boot.sp assembles (entirely in Sprint) under QEMU and checks the serial output.
# Needs qemu-system-x86_64; skipped (exit 0) when it is missing.
SPRINT=${SPRINT:-build/sprint}
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then echo "boot-test: qemu-system-x86_64 not found, skipped"; exit 0; fi
dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
"$SPRINT" run --allow-write="$dir" examples/boot/boot.sp "$dir/boot.img" >/dev/null || { echo "FAIL boot image build"; exit 1; }
sz=$(wc -c < "$dir/boot.img"); [ "$sz" -ge 16896 ] || { echo "FAIL image too small ($sz)"; exit 1; }
sig=$(od -An -tx1 -j510 -N2 "$dir/boot.img" | tr -d ' \n'); [ "$sig" = "55aa" ] || { echo "FAIL boot signature $sig"; exit 1; }
: > "$dir/serial.txt"
qemu-system-x86_64 -drive format=raw,file="$dir/boot.img" -serial file:"$dir/serial.txt" -display none -no-reboot -m 64 >/dev/null 2>&1 &
pid=$!
i=0
while [ $i -lt 100 ]; do
    grep -q "BOOT OK" "$dir/serial.txt" 2>/dev/null && break
    sleep 0.2; i=$((i+1))
done
kill $pid 2>/dev/null; wait $pid 2>/dev/null
out=$(cat "$dir/serial.txt")
want="Sprint long mode: fib(90) = 0x27f80ddaa1ba7878
BOOT OK"
if [ "$(printf '%s' "$out" | tr -d '\r')" = "$want" ]; then echo "boot-test: passed (long mode reached, fib(90) = 0x27f80ddaa1ba7878)"; else echo "FAIL boot-test: serial output was:"; echo "$out"; exit 1; fi
