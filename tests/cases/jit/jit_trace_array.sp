# array reads and writes inside trace-compiled loops: ints, floats, bools, rows of a matrix, out-of-range indices, an element that
# changes type, and a deoptimisation (an overflow) after a write in the same iteration, which must not apply the write twice
func total(a, n):
    let t = 0
    for i in range(n):
        t = t + a[i]
    return t
let ints = []
for i in range(3000):
    ints.append(i * 3 - 100)
print(total(ints, 3000), total(ints, 10))

func scale(a, n):
    for i in range(n):
        a[i] = a[i] * 2 + 1
    return a[n - 1]
print(scale(ints, 3000), ints[0], ints[2999])

func fsum(a, n):
    let t = 0.0
    for i in range(n):
        t = t + a[i]
    return t
let fl = []
for i in range(1000):
    fl.append(i * 0.5)
print(fsum(fl, 1000))

func flags_count(n):
    let f = []
    for i in range(n):
        f.append(true)
    let j = 0
    while j < n:
        f[j] = j % 3 == 0
        j += 1
    let c = 0
    for k in range(n):
        if f[k]:
            c += 1
    return c
print(flags_count(3000))

func rows(m, n):
    let t = 0
    for i in range(n):
        let r = m[i]
        for j in range(n):
            t = t + r[j]
    return t
let m = []
for i in range(40):
    let row = []
    for j in range(40):
        row.append(i * j)
    m.append(row)
print(rows(m, 40))

func past_end(a, n):
    let t = 0
    for i in range(n):
        t = t + a[i]
    return t
try:
    print(past_end(ints, 3001))
catch e:
    print(e.kind)

func negative_index(a, n):
    let t = 0
    for i in range(n):
        t = t + a[i - 5]
    return t
try:
    print(negative_index(ints, 3000))
catch e:
    print(e.kind)

func mixed_types(a, n):
    let t = 0
    for i in range(n):
        t = t + a[i]
    return t
let mixed = []
for i in range(2000):
    mixed.append(i)
mixed[1999] = 1.5
try:
    print(mixed_types(mixed, 2000))
catch e:
    print(e.kind)

# the write of an iteration happens after its last deopt point: the overflow at the end must leave the array as the interpreter would
func write_then_overflow(a, n):
    let big = 4611686018427387904
    let s = 0
    for i in range(n):
        a[i] = a[i] + 1
        s = s + big
    return s
let w = []
for i in range(10):
    w.append(i)
try:
    print(write_then_overflow(w, 10))
catch e:
    print(e.kind, w)

# two writes, the second one out of range: neither may happen in the trace's iteration
func two_writes(a, b, n):
    for i in range(n):
        a[i] = i
        b[i] = i * 2
    return 0
let p = []
let q = []
for i in range(2000):
    p.append(0)
for i in range(1999):
    q.append(0)
try:
    two_writes(p, q, 2000)
catch e:
    print(e.kind, p[1998], p[1999], q[1998])

# a failing operation whose result is never used must still fail (the optimiser may not delete it)
func dead_load(a, n):
    let b = 0
    for i in range(n):
        b = a[i - 3000]
        b = 7
    return b
try:
    print(dead_load(ints, 3003))
catch e:
    print(e.kind)

func dead_divide(n):
    let b = 0
    let d = 5
    for i in range(n):
        b = i // (d - i)
        b = 3
    return b
try:
    print(dead_divide(100))
catch e:
    print(e.kind)

func dead_overflow(n):
    let b = 1
    let s = 0
    for i in range(n):
        s = b * 4611686018427387904
        s = 1
        b = b + 1
    return s
try:
    print(dead_overflow(100))
catch e:
    print(e.kind)
