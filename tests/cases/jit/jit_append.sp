# Arrays grown by append / read with len() inside hot loops: contents, the element-type note and errors must equal the interpreter's.
func ints(n):
    let a = []
    for i in range(n):
        a.append(i * 3 % 17)
    let s = 0
    for x in a:
        s += x
    return [len(a), s]
print(ints(20000))

func fib(n):
    let a = [1, 1]
    let i = 2
    while len(a) < n:
        a.append((a[i - 1] + a[i - 2]) % 1000003)
        i += 1
    return [len(a), a[n - 1]]
print(fib(30000))

func floats(n):
    let a = []
    let x = 0.5
    for i in range(n):
        x = x * 1.0001 + 0.001
        a.append(x)
    return [len(a), a[0], a[n - 1]]
print(floats(8000))

func mixed_type(n):
    let a = []
    for i in range(n):
        if i < n - 5:
            a.append(i)
        else:
            a.append(i * 0.5)
    let t = 0.0
    for x in a:
        t += x
    return [len(a), t]
print(mixed_type(3000))

func bools_and_arrays(n):
    let flags = []
    let rows = []
    for i in range(n):
        flags.append(i % 3 == 0)
        rows.append([i, i * 2])
    let c = 0
    for f in flags:
        if f:
            c += 1
    return [c, len(rows), rows[n - 1][1]]
print(bools_and_arrays(5000))

func two_arrays(n):
    let a = []
    let b = []
    for i in range(n):
        a.append(i)
        b.append(i * i % 101)
    return [len(a), len(b), a[n - 1] + b[n - 1]]
print(two_arrays(6000))

func gc_pressure(n):
    let keep = []
    for i in range(n):
        let t = [i, i + 1, i + 2]
        if i % 7 == 0:
            keep.append(t)
    let s = 0
    for t in keep:
        s += t[0] + t[2]
    return [len(keep), s]
print(gc_pressure(40000))

func len_cond(n):
    let a = []
    let i = 0
    while i < n:
        a.append(i)
        if len(a) > 100 and i % 50 == 0:
            a.pop()
        i += 1
    return len(a)
print(len_cond(3000))
