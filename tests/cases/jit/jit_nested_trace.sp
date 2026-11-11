# A region around an outer loop calls the traces of its inner loops: every result, error and exit path must equal the interpreter's.
func sums(m, n):
    let s = 0
    let f = 0.0
    for k in range(m):
        let x = 0.5
        let i = 0
        while i < n:
            x = x * 0.999 + 0.001 * k
            s += i % 7
            i += 1
        f += x
    return [s, f]
print(sums(300, 40))

func with_break(m):
    let hits = 0
    let last = -1
    for k in range(m):
        let j = 0
        while j < 1000:
            j += 1
            if j * k > 5000:
                break
        hits += j
        last = j
    return [hits, last]
print(with_break(400))

func continue_in_inner(m, n):
    let c = 0
    for k in range(m):
        for i in range(n):
            if i % 3 == k % 3:
                continue
            c += i * k % 11
    return c
print(continue_in_inner(200, 60))

func shape_change(m):
    let acc = 0
    let x = 1
    for k in range(m):
        let i = 0
        while i < 50:
            acc += x
            i += 1
        if k == 150:
            x = 1.5
    return acc
print(shape_change(300))

func overflow_inner(m):
    let t = 0
    for k in range(m):
        let v = 1
        for i in range(70):
            v = v * 2
        t += v
    return t
try:
    print(overflow_inner(100))
catch e:
    print(e.kind)

func late_error(m):
    let s = 0
    for k in range(m):
        let a = [1, 2, 3, 4, 5, 6, 7, 8]
        for i in range(8 + (1 if k == 250 else 0)):
            s += a[i]
    return s
try:
    print(late_error(300))
catch e:
    print(e.kind)

func three(a, b, c):
    let s = 0.0
    for i in range(a):
        for j in range(b):
            let t = 0.0
            for k in range(c):
                t += (i + 1) * 0.5 + j * 0.25 - k
            s += t
    return s
print(three(30, 30, 30))

func early_return(m):
    let s = 0
    for k in range(m):
        let i = 0
        while i < 100:
            s += i
            i += 1
            if s > 100000:
                return [s, k, i]
    return [s, -1, 0]
print(early_return(1000))

func arrays_nested(n):
    let g = []
    for i in range(n):
        let row = []
        for j in range(n):
            row.append((i * j) % 10)
        g.append(row)
    let s = 0
    for i in range(1, n - 1):
        for j in range(1, n - 1):
            s += g[i - 1][j] + g[i + 1][j] - g[i][j - 1] * g[i][j + 1]
    return s
print(arrays_nested(80))

func after_inner(m):
    let tot = 0
    for k in range(m):
        let c = 0
        let i = 0
        while i < 30:
            c += i
            i += 1
        tot += c * k + i
    return tot
print(after_inner(500))
