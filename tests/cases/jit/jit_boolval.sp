# comparisons and and / or used as values (the result is stored, returned or passed on), with the operands changing type part way
func is_digit(c):
    return c >= 48 and c <= 57
func either(a, b):
    return a < 10 or b > 20
func pick(a, b):
    return a and b
func orelse(a, b):
    return a or b
func neg_lt(o, a, b):
    let m = 5
    let k = m * 3
    o[0] = not (m < a)
    o[1] = not (b >= 1.5)
    o[2] = not (k < m)
    return o
func cmpv(o, a, b):
    o[0] = a < b
    o[1] = a == b
    o[2] = a >= b
    o[3] = a != b
    return o
func fl(o, a, b):
    o[0] = a < b
    o[1] = a <= b
    o[2] = a > b
    o[3] = a >= b
    return o
func three(o, a, b, c):
    o[0] = a
    o[1] = b
    o[2] = c
    return o
func chain(o, a, b, c):
    return three(o, a, b or c, a and c)
func nan_cmp(o, x):
    let big = x * 1e308 * 10.0
    let n = big - big
    o[0] = n < 1.0
    o[1] = not (n < 1.0)
    o[2] = n >= n
    o[3] = not (n <= n)
    o[4] = not (n >= 1.0)
    return o
func run(n):
    let t = 0
    let O = [0, 0, 0, 0, 0]
    for i in range(n):
        if is_digit(i % 100):
            t += 1
        if either(i % 30, i % 40):
            t += 2
        let r = cmpv(O, i % 7, 3)
        if r[0]:
            t += 3
        if r[1]:
            t += 5
        if r[3]:
            t += 7
        let f = fl(O, i * 0.5, 40.0)
        if f[0]:
            t += 11
        if f[3]:
            t += 13
        let p = pick(i % 3 == 0, i % 5)
        if p:
            t += 17
        let o = orelse(nil, i % 4)
        if o == 2:
            t += 19
        let q = neg_lt(O, i % 9, i * 0.25)
        if q[0]:
            t += 23
        if q[1]:
            t += 29
        if q[2]:
            t += 31
        let z = chain(O, i % 2 == 0, nil, i)
        if z[1] == i:
            t += 37
        if z[2] == i:
            t += 41
    return t
print(run(5000))
print(is_digit(50), is_digit(5), either(1, 2), either(50, 2), pick(nil, 3), pick(2, 3), pick(false, 1), pick(true, nil))
print(orelse(false, nil), orelse(0, 1), orelse(nil, "x"), orelse(0.0, 2))
print(neg_lt([0, 0, 0], 2, 1.0), neg_lt([0, 0, 0], 9, 2.0))
let nn = [0, 0, 0, 0, 0]
for i in range(300):
    nan_cmp(nn, 1.5)
print(nn, nan_cmp([0, 0, 0, 0, 0], 2.5))
print(chain([0, 0, 0], 1, nil, 2), chain([0, 0, 0], nil, false, 3))
# the operand types change after the function is hot: mixed compares must raise the same errors
func mixed(a, b):
    return a < b or a == b
let acc = 0
for i in range(3000):
    if mixed(i, 1500):
        acc += 1
print(acc, mixed(1.5, 2), mixed("a", "b"))
try:
    mixed(1, "x")
catch e:
    print(e.kind)
try:
    mixed(nil, 1)
catch e:
    print(e.kind)
