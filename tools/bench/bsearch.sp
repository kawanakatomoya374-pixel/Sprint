func bs(a, n, key):
    let lo = 0
    let hi = n - 1
    while lo <= hi:
        let mid = (lo + hi) // 2
        let v = a[mid]
        if v < key:
            lo = mid + 1
        elif v > key:
            hi = mid - 1
        else:
            return mid
    return -1
let n = 1000000
let a = []
a.reserve(n)
for i in range(n):
    a.append(i * 3)
let seed = 43
let found = 0
for q in range(3000000):
    seed = (seed * 16807) % 2147483647
    if bs(a, n, seed % (n * 3)) >= 0:
        found += 1
print(found)
