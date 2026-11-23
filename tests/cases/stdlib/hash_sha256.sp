# hash.sha256 on a string, an array of bytes and a typed array; known digests (FIPS 180-2 test vectors)
import hash
import typed

let D = "0123456789abcdef"
func hx(t):
    let s = ""
    for b in t:
        s = s .. D.slice(b // 16, b // 16 + 1) .. D.slice(b % 16, b % 16 + 1)
    return s

print(hx(hash.sha256("")))
print(hx(hash.sha256("abc")))
print(hx(hash.sha256([97, 98, 99])))
let t = typed.u8(3)
t[0] = 97
t[1] = 98
t[2] = 99
print(hx(hash.sha256(t)))
print(hx(hash.sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")))
print(len(hash.sha256("x")))
try:
    hash.sha256([256])
catch e:
    print(e.kind)
try:
    hash.sha256(5)
catch e:
    print(e.kind)
