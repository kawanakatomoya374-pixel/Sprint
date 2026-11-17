# float + and * whose right operand dies at the operation (the result takes its register)
func kern(a, b, c, n, f, g):
    for i in range(n):
        let x = a[i]
        let y = b[i]
        c[i] = f * y + x
        a[i] = g * x * y - f
        b[i] = y * f + g * x
    return 0

func chain(xs, n, f):
    let s = 0.0
    for i in range(n):
        let v = xs[i]
        s = s + f * v
        s = v * s * 0.5 + f * f * v
    return s

let n = 300
let a = []
let b = []
let c = []
for i in range(n):
    a.append(i * 0.01 + 1.0)
    b.append(2.0 - i * 0.003)
    c.append(0.0)
for r in range(40):
    kern(a, b, c, n, 0.5, 0.25)
    for i in range(n):
        if a[i] > 100.0 or a[i] < -100.0:
            a[i] = 1.0
        if b[i] > 100.0 or b[i] < -100.0:
            b[i] = 1.0
print(a[0], a[299], b[0], b[299], c[5])
let xs = []
for i in range(n):
    xs.append((i % 17) * 0.1)
let t = 0.0
for r in range(40):
    t += chain(xs, n, 0.5)
print(t)
