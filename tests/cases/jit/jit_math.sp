import math
func f(n):
    let s = 0.0
    for i in range(n):
        let x = i * 0.01
        s += math.sqrt(x) + math.sin(x) * math.cos(x) + math.exp(x * 0.001) + math.tan(x * 0.1) + math.atan(x)
    return s
print(f(3000))

func g(n):
    let s = 0.0
    for i in range(n):
        s += math.sqrt(i)
    return s
print(g(3000))

func neg(n):
    let s = 0.0
    for i in range(n):
        s += math.sqrt(40 - i)
    return s
try:
    print(neg(100))
catch e:
    print("caught", e.kind)

func nb(steps):
    let x = 0.0
    let y = 1.0
    let vx = 0.5
    let vy = 0.0
    let dt = 0.001
    for i in range(steps):
        let r2 = x * x + y * y
        let r3 = r2 * math.sqrt(r2)
        vx -= x / r3 * dt
        vy -= y / r3 * dt
        x += vx * dt
        y += vy * dt
    return x + y
print(nb(20000))
