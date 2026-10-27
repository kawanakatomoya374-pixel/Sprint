# fused instructions must behave exactly like the plain ones, including when operand types change
func acc_int(n):
    let s = 0
    for i in range(n):
        s += i % 7
        s += i * 3
        s += i
    return s
print(acc_int(1000))

func acc_mixed():
    let s = 0
    let x = 2.5
    for i in range(4):
        s += i
        s += x
    return s
print(acc_mixed())

func acc_str():
    let s = ""
    let t = "ab"
    for i in range(3):
        s += t
    return s
try:
    print(acc_str())
catch e:
    print("caught", e.kind)

func acc_overflow():
    let s = 9223372036854775800
    let k = 5
    for i in range(3):
        s += k
    return s
try:
    print(acc_overflow())
catch e:
    print("caught", e.kind)

let g = 0
for i in range(100):
    g += i % 5
    g += i
print(g)
let gf = 0.5
let h = 1.5
for i in range(3):
    gf += h
print(gf)

func floats():
    let a = 1.5
    let b = 2.5
    let c = a * b
    c = c / a
    let d = a - b
    let e = a + b
    let n = 0
    if a < b:
        n += 1
    if a <= b:
        n += 1
    if a > b:
        n += 10
    if a == b:
        n += 100
    if a != b:
        n += 1000
    return [c, d, e, n, 7.0 / 2.0, 1.0 / 4.0]
print(floats())

func nan_cmp():
    let z = 0.0
    let nan = z / 1.0
    let a = 3
    let b = 1.5
    return [a < b, a > b, 1.5 < 2, 2 > 1.5]
print(nan_cmp())

func divzero():
    let a = 1.0
    let b = 0.0
    return a / b
try:
    print(divzero())
catch e:
    print("caught", e.kind)

func setidx():
    let a = [1, 2, 3, 4]
    let i = 2
    let v = 9
    a[i] = v
    a[0] = true
    a[1] = false
    let j = 7
    try:
        a[j] = v
    catch e:
        print("caught", e.kind)
    return a
print(setidx())

func getidx():
    let m = [[1, 2], [3, 4]]
    let i = 1
    let k = 0
    let t = {"x": [5, 6]}
    let key = "x"
    let s = "hey"
    return [m[i][k], t[key][1], s[1], m[i][k] * 2 + 1]
print(getidx())

func collatz(n):
    let c = 0
    while n != 1:
        if n % 2 == 0:
            n = n // 2
        else:
            n = 3 * n + 1
        c += 1
    return c
print(collatz(27), collatz(97))

func negdiv():
    let a = -7
    let r = []
    r.append(a // 2)
    r.append(a // 3)
    r.append(7 // 2)
    r.append(a % 3)
    let f = 7.5
    r.append(f // 2)
    return r
print(negdiv())

func si_cmp(x):
    let n = 0
    if x == 3:
        n += 1
    if x != 3:
        n += 2
    if x < 3:
        n += 4
    if x >= 3:
        n += 8
    return n
print(si_cmp(3), si_cmp(1), si_cmp(5), si_cmp(3.0))

func counter():
    let n = 0
    func inc():
        n += 1
        return n
    return inc
let c1 = counter()
c1()
c1()
print(c1())
func fcounter():
    let n = 0.5
    func inc():
        n += 1
        return n
    return inc
let c2 = fcounter()
c2()
print(c2())

func longstr():
    let a = "x".repeat(100) .. "y"
    let b = "x".repeat(100) .. "y"
    let t = {}
    t[a] = 1
    t[b] += 1
    let m = {}
    m["k" .. "1"] = 5
    return [a == b, t[a], len(t), m["k1"]]
print(longstr())
