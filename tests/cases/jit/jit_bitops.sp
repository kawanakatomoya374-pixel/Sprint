# Bitwise operations and shifts in hot loops: the JIT results (and errors) must equal the interpreter's.
func mix(n):
    let x = 2463534242
    let acc = 0
    for i in range(n):
        x = (x ^ (x << 13)) & 0xFFFFFFFF
        x = x ^ (x >> 17)
        x = (x ^ (x << 5)) & 0xFFFFFFFF
        acc = (acc + (x & 255) + (x | 7) % 11 + (x >> 28)) % 1000003
    return [x, acc]
print(mix(20000))

func neg(n):
    let a = 0
    let b = 0
    let c = 0
    for i in range(-n, n):
        a += (i & 0xFF) + (i | 3) % 5
        b += (i ^ 0x55) % 13 + (i >> 2) + (i >> 63)
        c += ~i + (~i & 7) + (i << 3) % 9
    return [a, b, c]
print(neg(3000))

func consts(n):
    let s = 0
    for i in range(n):
        s += (1 << (i % 62)) % 1000003
        s += (-1 << (i % 40)) % 997
        s += (0x7FFFFFFFFFFFFFFF >> (i % 64)) % 31
        s += (i << 62) % 3
    return s
print(consts(3000))

func sieve(m):
    let words = (m >> 5) + 1
    let bits = []
    for i in range(words):
        bits.append(0xFFFFFFFF)
    let count = 0
    for i in range(2, m + 1):
        if ((bits[i >> 5] >> (i & 31)) & 1) == 1:
            count += 1
            let j = i + i
            while j <= m:
                bits[j >> 5] &= ~(1 << (j & 31))
                j += i
    return count
print(sieve(200000))

func crc(n):
    let t = []
    for i in range(256):
        let c = i
        for k in range(8):
            if (c & 1) == 1:
                c = 0xEDB88320 ^ (c >> 1)
            else:
                c = c >> 1
        t.append(c)
    let r = 0xFFFFFFFF
    for i in range(n):
        r = t[(r ^ i) & 255] ^ (r >> 8)
    return r ^ 0xFFFFFFFF
print(crc(30000))

# a shift count outside 0 .. 63 leaves the compiled code: >= 64 saturates, a negative count is a ValueError
func big_shift(n):
    let s = 0
    for i in range(n):
        s += (i << (i % 70)) % 1009 + (-i >> (i % 70)) % 1013
    return s
print(big_shift(5000))

func bad_shift(n):
    let s = 0
    for i in range(n):
        s += (i + 5) >> (3 - i // 50)
    return s
try:
    print(bad_shift(400))
catch e:
    print(e.kind)

func mixed_types(n):
    let s = 0
    for i in range(n):
        s += i & 3
        if i == n - 1:
            s += 1.5 & 1
    return s
try:
    print(mixed_types(300))
catch e:
    print(e.kind)
