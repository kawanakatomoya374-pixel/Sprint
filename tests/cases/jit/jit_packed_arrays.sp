# Arrays of bools / ints / floats store 8-byte payloads; every operation, a change of element type, and the JIT paths must agree with the interpreter.
func fill_ints(n):
    let a = []
    for i in range(n):
        a.append(i * 7 % 101)
    let s = 0
    for i in range(n):
        s += a[i]
        a[i] = a[i] + 1
    for x in a:
        s += x
    return [len(a), s]
print(fill_ints(5000))

func floats(n):
    let a = []
    for i in range(n):
        a.append(i * 0.25)
    let s = 0.0
    for i in range(n):
        a[i] = a[i] * 1.5 + 1.0
        s += a[i]
    return [s, a[n - 1]]
print(floats(4000))

func bools(n):
    let f = []
    for i in range(n):
        f.append(i % 3 != 0)
    let c = 0
    for i in range(n):
        if f[i]:
            c += 1
        f[i] = not f[i]
    for x in f:
        if x:
            c += 10
    return c
print(bools(3000))

func type_change(n):
    let a = []
    for i in range(n):
        a.append(i)
    a[3] = 2.5
    a[5] = "five"
    a.append(nil)
    let kinds = 0
    for x in a:
        if x == 2.5 or x == "five" or x == nil:
            kinds += 1
    return [len(a), kinds, a[4], a[3], a[5]]
print(type_change(200))

func refill():
    let a = [1, 2, 3]
    a.pop()
    a.pop()
    a.pop()
    a.append("x")
    a.append("y")
    let b = []
    b.append(1.5)
    b.pop()
    b.append(7)
    b.append(8)
    return [a, b, len(a) + len(b)]
print(refill())

func ops(n):
    let a = []
    for i in range(n):
        a.append(i * 3 % 17)
    a.insert(2, 99)
    a.insert(0, -1)
    a.insert(len(a), 5)
    let r = a.remove_at(4)
    let c = a.slice(3, 40)
    let d = a.copy()
    d.reverse()
    d.extend(c)
    a.sort()
    let m = a.map(func(x): x * 2)
    let f = m.filter(func(x): x % 3 == 0)
    return [r, c[0], d[0], d[len(d) - 1], a[0], a[len(a) - 1], len(m), len(f), a.index_of(99), 99 in a]
print(ops(60))

func floats_sort(n):
    let a = []
    let x = 0.37
    for i in range(n):
        x = (x * 3.9 * (1.0 - x)) % 1.0
        a.append(x)
    a.sort()
    let ok = true
    for i in range(1, n):
        if a[i - 1] > a[i]:
            ok = false
    return [ok, len(a)]
print(floats_sort(2000))

func nested(n):
    let rows = []
    for i in range(n):
        let r = []
        for j in range(n):
            r.append(i * j % 10)
        rows.append(r)
    let s = 0
    for i in range(n):
        for j in range(n):
            s += rows[i][j]
            rows[i][j] = rows[i][j] + 1
    return s
print(nested(60))

func mixed_literals():
    let a = [1, 2, 3, 4]
    let b = [1.5, 2.5]
    let c = [true, false, true]
    let d = [1, 2.5]
    let e = [[1, 2], [3, 4]]
    return [a, b, c, d, e, len(a) + len(b) + len(c) + len(d) + len(e)]
print(mixed_literals())

func store_other_type(n):
    let a = []
    for i in range(n):
        a.append(i)
    let s = 0
    for i in range(n):
        s += a[i]
        if i == n - 3:
            a[i] = 0.5
    return [s, a[n - 3], a[n - 2]]
print(store_other_type(400))

func shuffle_choice():
    let a = []
    for i in range(100):
        a.append(i)
    a.reverse()
    return [a[0], a[99], len(a), a.index_of(50)]
print(shuffle_choice())
