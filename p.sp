import math
func f(n):
    let a = 0.5
    let b = 1.25
    let c = 2.0
    let d = 0.75
    for i in range(n):
        c = math.sqrt((c - (math.sqrt(3 * 3 + 1.0) * a)) * (c - (math.sqrt(3 * 3 + 1.0) * a)) + 1.0)
        d = d
        b = c
        a = (c + math.sqrt(3 * 3 + 1.0))
        a = (math.sqrt(a * a + 1.0) / ((a + ((d * c) * (b + 3))) + 1.0 + (a + ((d * c) * (b + 3))) * (a + ((d * c) * (b + 3)))))
        if a > 1000000.0 or a < -1000000.0:
            a = 0.5
        if b > 1000000.0 or b < -1000000.0:
            b = 1.25
        if c > 1000000.0 or c < -1000000.0:
            c = 2.0
        if d > 1000000.0 or d < -1000000.0:
            d = 0.75
    return [a,b,c,d]
print(f(300))
