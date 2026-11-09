func is_digit(c):
    return c >= 48 and c <= 57
func is_alpha(c):
    return (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or c == 95
func add3(a, b, c):
    return a + b * c
func sq(a):
    return a * a
func inrange(a, lo, hi):
    return a >= lo and a < hi
func count(s):
    let d = 0
    let a = 0
    let o = 0
    let i = 0
    let n = len(s)
    while i < n:
        let c = s[i]
        if is_digit(c):
            d += 1
        elif is_alpha(c):
            a += 1
        else:
            o += 1
        i += 1
    return [d, a, o]
let text = "abc_123 XYZ 99 foo(bar, 42)\n".repeat(2000)
print(count(text))
func mixed(n):
    let t = 0
    for i in range(n):
        let x = i
        if i == 700:
            x = 5.5
        if is_digit(x + 40):
            t += 1
    return t
print(mixed(1000))
func mixed2(n):
    let t = 0
    for i in range(n):
        t += add3(i, 3, 4)
    return t
print(mixed2(1000))
func ov(n):
    let t = 0
    for i in range(n):
        t += sq(i * 1000000000)
    return t
try:
    print(ov(100))
catch err:
    print(err.kind)
func rng(n):
    let t = 0
    for i in range(n):
        if inrange(i, 100, 200):
            t += 1
    return t
print(rng(1000))
func bools(n):
    let t = 0
    for i in range(n):
        let b = is_digit(i)
        if b:
            t += 1
    return t
print(bools(200))
