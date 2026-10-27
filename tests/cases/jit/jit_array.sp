func fill(n):
    let a = []
    for i in range(n):
        a.append(i * i % 17)
    return a
let a = fill(5000)
print(len(a), a[0], a[1], a[4999])

func total(arr):
    let t = 0
    for i in range(len(arr)):
        t += arr[i]
    for x in arr:
        t += x * 2
    for i, x in arr:
        t += i - x
    return t
print(total(a))

func sieve(n):
    let flags = []
    for i in range(n + 1):
        flags.append(true)
    flags[0] = false
    flags[1] = false
    let i = 2
    while i * i <= n:
        if flags[i]:
            let j = i * i
            while j <= n:
                flags[j] = false
                j += i
        i += 1
    let c = 0
    for f in flags:
        if f:
            c += 1
    return c
print(sieve(20000))

func oob(arr, n):
    let s = 0
    for i in range(n):
        s += arr[i]
    return s
try:
    print(oob([1, 2, 3], 100))
catch e:
    print("caught", e.kind)

func neg_index(arr, n):
    let s = 0
    for i in range(n):
        s += arr[i - 50]
    return s
try:
    print(neg_index(fill(100), 100))
catch e:
    print("caught", e.kind)

func mixedtypes(n):
    let arr = [1, 2.5, 3, "x", nil, true]
    let c = 0
    for i in range(n):
        let v = arr[i % 6]
        if v:
            c += 1
    return c
print(mixedtypes(600))

func notnum(n):
    let arr = [1, 2, 3, "four", 5]
    let s = 0
    for i in range(n):
        s += arr[i % 5]
    return s
try:
    print(notnum(100))
catch e:
    print("caught", e.kind)

func matrix(n):
    let m = []
    for i in range(n):
        let row = []
        for j in range(n):
            row.append(i * j % 5 + 1)
        m.append(row)
    let s = 0
    for i in range(n):
        for j in range(n):
            s += m[i][j] * m[j][i]
    return s
print(matrix(60))

func grow(n):
    let a = [1]
    let s = 0
    for x in a:
        s += x
        if len(a) < n:
            a.append(x + 1)
            a.append(x + 2)
    return [s, len(a)]
print(grow(300))

func setget(n):
    let a = [0, 0, 0, 0]
    for i in range(n):
        a[i % 4] = a[(i + 1) % 4] + i
        a[2] = 1.5
    a.append("s")
    return a
print(setget(20))

let g = [1, 2, 3]
func modarr(n):
    for i in range(n):
        g[i % 3] += i
    return g
print(modarr(1000))
