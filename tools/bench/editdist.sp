func fill(n, v):
    let a = []
    a.reserve(n)
    for i in range(n):
        a.append(v)
    return a
func dist(a, b):
    let n = len(a)
    let m = len(b)
    let prev = fill(m + 1, 0)
    let cur = fill(m + 1, 0)
    for j in range(m + 1):
        prev[j] = j
    for i in range(1, n + 1):
        cur[0] = i
        let ca = a[i - 1]
        for j in range(1, m + 1):
            let cost = 0 if ca == b[j - 1] else 1
            let x = prev[j] + 1
            let y = cur[j - 1] + 1
            let z = prev[j - 1] + cost
            if y < x:
                x = y
            if z < x:
                x = z
            cur[j] = x
        let t = prev
        prev = cur
        cur = t
    return prev[m]
let seed = 9
let letters = "abcdef"
let s1 = []
let s2 = []
for i in range(2500):
    seed = (seed * 16807) % 2147483647
    s1.append(letters[seed % 6:seed % 6 + 1])
    seed = (seed * 16807) % 2147483647
    s2.append(letters[seed % 6:seed % 6 + 1])
let w1 = s1.join("")
let w2 = s2.join("")
print(dist(w1, w2))
