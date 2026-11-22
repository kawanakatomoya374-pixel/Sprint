# Assembles an x86 source file to a flat binary with the Sprint assembler (stdlib/asm.sp).
# usage: sprint run --allow-read=DIR --allow-write=DIR tools/asm/asm.sp [--bits N] [--org ADDR] [--boot] IN.asm OUT.bin [--map]
#   --boot  pads the image to 510 bytes and appends the 0xAA55 boot signature (bits 16, org 0x7c00 unless given)
import asm
import fs
import sys
let a = sys.args
let opts = {bits: 16, org: 0}
let boot = false
let map = false
let files = []
let i = 0
while i < len(a):
    if a[i] == "--bits":
        opts.bits = to_int(a[i + 1])
        i += 1
    elif a[i] == "--org":
        opts.org = to_int(a[i + 1])
        i += 1
    elif a[i] == "--boot":
        boot = true
    elif a[i] == "--map":
        map = true
    else:
        files.append(a[i])
    i += 1
if len(files) != 2:
    print("usage: asm.sp [--bits N] [--org ADDR] [--boot] [--map] IN.asm OUT.bin")
    sys.exit(2)
let src = fs.read_file(files[0])
let r = nil
if boot:
    r = asm.boot_sector(src, opts)
else:
    r = asm.assemble(src, opts)
fs.write_bytes(files[1], r.bytes)
if map:
    for k, v in r.symbols:
        print(k, v)
print("wrote " .. to_string(len(r.bytes)) .. " bytes to " .. files[1])
