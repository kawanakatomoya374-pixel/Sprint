import math
# Float values kept in xmm registers by the TraceJIT: every result must equal the interpreter's.
class P:
    let x = 0.0
    let y = 0.0
    func init(self, x, y):
        self.x = x
        self.y = y
    func step(self, dt):
        self.x = self.x + self.y * dt
        self.y = self.y - self.x * dt
func swap(n):
    let a = 1.5
    let b = 2.5
    let c = 0.25
    for i in range(n):
        let t = a
        a = b + 0.125
        b = c * 1.01
        c = t - 0.0625
    return [a, b, c]
print(swap(3000))

func mixed(n):
    let s = 0.0
    let t = 0
    for i in range(n):
        s += i * 0.5 + i / 4 - (i + 1) / 3
        t += i
        s -= t * 1.5
    return s
print(mixed(5000))

func negs(n):
    let x = 0.1
    let y = -3.0
    for i in range(n):
        x = -x * 1.0001 + y * 0.0001
        y = -(y - x) * 0.5
    return [x, y]
print(negs(4000))

func arrays(n):
    let a = [0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5]
    let b = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
    let acc = 0.0
    for i in range(n):
        b[i % 8] = a[(i + 3) % 8] * 0.99 + a[i % 8] * 0.01 + i
        acc += a[(i * 5) % 8] - a[(i + 1) % 8] * 0.5
    return [acc, b[0], b[7]]
print(arrays(6000))

func fields2(n):
    let p = P(1.0, 0.5)
    for i in range(n):
        p.x = p.x + p.y * 0.01
        p.y = p.y - p.x * 0.01
    return [p.x, p.y]

func nan_cmp(n):
    let x = 1.0
    let c = 0
    for i in range(n):
        x = x * 1.5 - 0.5
        if x < 1000.0:
            c += 1
        if x >= 0.0:
            c += 2
        if x != x:
            c += 100
    return [c, x]
print(nan_cmp(40))

func divzero(n):
    let s = 0.0
    for i in range(n):
        s += 10.0 / (30.0 - i)
    return s
try:
    print(divzero(100))
catch e:
    print(e.kind)

func intdiv_float(n):
    let s = 0.0
    for i in range(n):
        s += 7 / (i + 1) + (i + 2) / 5
    return s
print(intdiv_float(4000))

func fields(n):
    let p = P(1.0, 0.5)
    for i in range(n):
        p.step(0.01)
    return [p.x, p.y]
print(fields(5000))
print(fields2(5000))

func pressure(n):
    let a = 1.0
    let b = 2.0
    let c = 3.0
    let d = 4.0
    let e = 5.0
    let f = 6.0
    let g = 7.0
    let h = 8.0
    let k = 9.0
    let m = 10.0
    for i in range(n):
        a = a * 0.99 + b * 0.01
        b = b * 0.99 + c * 0.01
        c = c * 0.99 + d * 0.01
        d = d * 0.99 + e * 0.01
        e = e * 0.99 + f * 0.01
        f = f * 0.99 + g * 0.01
        g = g * 0.99 + h * 0.01
        h = h * 0.99 + k * 0.01
        k = k * 0.99 + m * 0.01
        m = m * 0.99 + a * 0.01
    return [a, b, c, d, e, f, g, h, k, m]
print(pressure(3000))

func mathmix(n):
    let s = 0.0
    for i in range(1, n):
        s += math.sqrt(i * 1.0) / i + math.sin(i * 0.001)
    return s
print(mathmix(3000))
