func popcount(x):
    let c = 0
    while x != 0:
        x &= x - 1
        c += 1
    return c
func crc_table():
    let t = []
    for i in range(256):
        let c = i
        for k in range(8):
            if (c & 1) == 1:
                c = 0xEDB88320 ^ (c >> 1)
            else:
                c = c >> 1
        t.append(c)
    return t
let tab = crc_table()
let x = 2463534242
let pc = 0
let crc = 0xFFFFFFFF
for i in range(3000000):
    x = (x ^ (x << 13)) & 0xFFFFFFFF
    x = x ^ (x >> 17)
    x = (x ^ (x << 5)) & 0xFFFFFFFF
    pc += popcount(x)
    crc = tab[(crc ^ x) & 255] ^ (crc >> 8)
print(pc, crc ^ 0xFFFFFFFF)
