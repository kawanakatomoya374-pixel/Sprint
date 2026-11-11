func fill(n, v):
    let a = []
    a.reserve(n)
    for i in range(n):
        a.append(v)
    return a
func lcs(a, b):
    let n = len(a)
    let m = len(b)
    let prev = fill(m + 1, 0)
    let cur = fill(m + 1, 0)
    for i in range(1, n + 1):
        let ai = a[i - 1]
        for j in range(1, m + 1):
            if ai == b[j - 1]:
                cur[j] = prev[j - 1] + 1
            elif prev[j] >= cur[j - 1]:
                cur[j] = prev[j]
            else:
                cur[j] = cur[j - 1]
        let t = prev
        prev = cur
        cur = t
    return prev[m]
let seed = 17
let a = []
let b = []
for i in range(9000):
    seed = (seed * 16807) % 2147483647
    a.append(seed % 4)
    seed = (seed * 16807) % 2147483647
    b.append(seed % 4)
print(lcs(a, b))
