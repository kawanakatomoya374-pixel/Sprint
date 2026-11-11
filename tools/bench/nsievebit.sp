func nsieve(m):
    let words = (m >> 5) + 1
    let bits = []
    bits.reserve(words)
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
print(nsieve(8000000))
