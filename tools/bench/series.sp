import math
func f(x):
    return math.sin(x) * math.exp(0.0 - x * 0.1) + 1.0
func trapezoid(a, b, n):
    let h = (b - a) / n
    let s = (f(a) + f(b)) * 0.5
    for i in range(1, n):
        s += f(a + i * h)
    return s * h
let t = 0.0
for r in range(150):
    t += trapezoid(0.0, 20.0 + r, 80000)
print(math.floor(t * 100000))
