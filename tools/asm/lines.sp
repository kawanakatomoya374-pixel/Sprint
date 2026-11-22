# prints the encoding of every line of a source file, one line per instruction: "<hex>" or "ERR <message>".
# usage: sprint run --allow-read=DIR lines.sp BITS FILE
import asm
import fs
import sys
let HEXD = "0123456789abcdef"
let bits = to_int(sys.args[0])
let lines = fs.read_file(sys.args[1]).split("\n")
for ln in lines:
    if len(ln.trim()) == 0:
        continue
    try:
        let r = asm.assemble(ln, {bits: bits})
        let s = ""
        for b in r.bytes:
            s = s .. HEXD.slice(b // 16, b // 16 + 1) .. HEXD.slice(b % 16, b % 16 + 1)
        print(s)
    catch e:
        print("ERR " .. e.message)
