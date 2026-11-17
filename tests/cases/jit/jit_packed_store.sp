# stores into packed arrays inside a range loop: the entry checks stand in for the per-store bounds / note checks
func scale(a, n, f):
    for i in range(n):
        a[i] = a[i] * f

func axpy(y, x, n, f):
    for i in range(n):
        y[i] -= f * x[i]

func fillk(a, n, v):
    for i in range(n):
        a[i] = v

func total(a, n):
    let s = 0.0
    for i in range(n):
        s += a[i]
    return s

let n = 200
let a = []
let b = []
for i in range(n):
    a.append(i * 0.5)
    b.append(1.0)
for r in range(40):
    scale(a, n, 1.01)
    axpy(b, a, n, 0.001)
print(total(a, n), total(b, n))

# the same array under two names
let c = a
for r in range(30):
    axpy(a, c, n, 0.0001)
    scale(c, n, 0.999)
print(total(a, n))

# a store that changes the array's element type between runs (packed -> boxed): the entry checks must notice
let m = []
for i in range(n):
    m.append(1.5)
for r in range(30):
    scale(m, n, 1.1)
m[7] = "x"
m[7] = 2.5
for r in range(30):
    scale(m, n, 1.1)
print(total(m, n))
let k = []
for i in range(n):
    k.append(3)
for r in range(30):
    fillk(k, n, 7)
k[3] = 1.5
fillk(k, n, 9)
print(k[0], k[3], k[199])

# a shorter array than the bound used by an earlier run
let sh = []
for i in range(50):
    sh.append(1.0)
for r in range(30):
    scale(sh, 50, 1.5)
print(total(sh, 50) > 0.0)
