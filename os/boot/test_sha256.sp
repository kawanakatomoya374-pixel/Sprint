# Runs the loader's assembly SHA-256 on this machine (x86-64) and compares it with the native hash module for many lengths.
# usage: sprint run --allow-ffi --allow-asm os/boot/test_sha256.sp
import asm
import ffi
import hash
import sha256_asm

let src = "bits 64\ndefault rel\n    jmp sha256_all\n" .. sha256_asm.text()
let code = asm.assemble(src, {bits: 64}).bytes
let f = ffi.asm(code, "void(void*, void*, int64_t)")
let ctx = ffi.array("u8", sha256_asm.CTX_SIZE)
let bad = 0
let tested = 0
let lengths = []
for n in range(0, 200):
    lengths.append(n)
for n in [255, 256, 1000, 4096, 65535, 100000]:
    lengths.append(n)
for n in lengths:
    let data = ffi.array("u8", n if n > 0 else 1)
    let plain = []
    for i in range(n):
        let v = (i * 131 + n * 7 + 13) & 255
        data.set(i, v)
        plain.append(v)
    f(ctx.addr(), data.addr(), n)
    let want = sha256_asm.words(hash.sha256(plain))
    for i in range(8):
        let got = ctx.get(4 * i) | (ctx.get(4 * i + 1) << 8) | (ctx.get(4 * i + 2) << 16) | (ctx.get(4 * i + 3) << 24)
        if got != want[i]:
            bad += 1
            print("MISMATCH at length", n, "word", i)
            break
    tested += 1
print("sha256 asm:", tested, "lengths,", bad, "mismatches")
