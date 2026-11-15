import math
func is_prime(n):
    if n < 2:
        return false
    if n % 2 == 0:
        return n == 2
    let i = 3
    let lim = to_int(math.sqrt(n))
    while i <= lim:
        if n % i == 0:
            return false
        i += 2
    return true
func gcd(a, b):
    while b != 0:
        let t = a % b
        a = b
        b = t
    return a
let c = 0
for n in range(1, 400000):
    if is_prime(n):
        c += 1
let g = 0
for a in range(1, 1500):
    for b in range(1, 600):
        g += gcd(a, b)
print(c, g)
