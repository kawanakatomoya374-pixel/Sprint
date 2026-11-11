func fill(n, v):
    let a = []
    a.reserve(n)
    for i in range(n):
        a.append(v)
    return a
func heapsort(a, n):
    let l = n // 2
    let ir = n - 1
    while true:
        let rra = 0.0
        if l > 0:
            l -= 1
            rra = a[l]
        else:
            rra = a[ir]
            a[ir] = a[0]
            ir -= 1
            if ir == 0:
                a[0] = rra
                return
        let i = l
        let j = l * 2 + 1
        while j <= ir:
            if j < ir and a[j] < a[j + 1]:
                j += 1
            if rra < a[j]:
                a[i] = a[j]
                i = j
                j = j * 2 + 1
            else:
                j = ir + 1
        a[i] = rra
let n = 600000
let a = fill(n, 0.0)
let seed = 42
for i in range(n):
    seed = (seed * 16807) % 2147483647
    a[i] = seed / 2147483647.0
heapsort(a, n)
let ok = true
for i in range(1, n):
    if a[i - 1] > a[i]:
        ok = false
print(ok, a[0] < a[n - 1])
