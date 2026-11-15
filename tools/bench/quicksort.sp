func qsort(a, lo, hi):
    while lo < hi:
        let p = a[(lo + hi) // 2]
        let i = lo
        let j = hi
        while i <= j:
            while a[i] < p:
                i += 1
            while a[j] > p:
                j -= 1
            if i <= j:
                let t = a[i]
                a[i] = a[j]
                a[j] = t
                i += 1
                j -= 1
        if j - lo < hi - i:
            qsort(a, lo, j)
            lo = i
        else:
            qsort(a, i, hi)
            hi = j
let n = 700000
let a = []
a.reserve(n)
let seed = 47
for i in range(n):
    seed = (seed * 16807) % 2147483647
    a.append(seed)
qsort(a, 0, n - 1)
let ok = true
for i in range(1, n):
    if a[i - 1] > a[i]:
        ok = false
print(ok, a[0], a[n - 1])
