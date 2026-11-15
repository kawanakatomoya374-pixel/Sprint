let seed = 37
let parts = []
for i in range(200000):
    seed = (seed * 16807) % 2147483647
    let run = 1 + seed % 6
    let ch = 97 + (seed // 7) % 4
    for k in range(run):
        parts.append(ch)
func encode(a):
    let out = []
    let i = 0
    let n = len(a)
    while i < n:
        let c = a[i]
        let j = i
        while j < n and a[j] == c:
            j += 1
        out.append(c)
        out.append(j - i)
        i = j
    return out
func decode(e):
    let out = []
    let i = 0
    while i < len(e):
        let c = e[i]
        let k = e[i + 1]
        for t in range(k):
            out.append(c)
        i += 2
    return out
let total = 0
for r in range(8):
    let e = encode(parts)
    let d = decode(e)
    total += len(e) + len(d)
print(total)
