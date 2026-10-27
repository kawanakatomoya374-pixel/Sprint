let total = 0
for i in range(2000):
    total += i % 7
print(total)

let w = 0
let k = 0
while k < 3000:
    k += 1
    if k % 3 == 0:
        continue
    if k > 2500:
        break
    w += k
print(w, k)

func nested(n):
    let c = 0
    for i in range(n):
        for j in range(i):
            if (i + j) % 3 == 0:
                c += 1
            elif (i * j) % 5 == 1:
                c += 2
    return c
print(nested(120))

func steps(n):
    let c = 0
    while n != 1:
        if n % 2 == 0:
            n = n // 2
        else:
            n = 3 * n + 1
        c += 1
    return c
let best = 0
for i in range(1, 3000):
    let s = steps(i)
    if s > best:
        best = s
print(best)

func ranges():
    let a = 0
    for i in range(10, 0, -3):
        a = a * 10 + i
    for i in range(0, 100, 7):
        a += i
    for i in range(5, 5):
        a += 1000000
    for i in range(0, -50, -1):
        a -= 1
    return a
print(ranges())

func zerostep(n):
    let s = 0
    for i in range(n):
        for j in range(0, 10, n - 3 - i):
            s += 1
    return s
try:
    print(zerostep(100))
catch e:
    print("caught", e.kind)

func early(n):
    for i in range(n):
        if i * i > 5000:
            return i
    return -1
print(early(1000))

func andor(n):
    let c = 0
    for i in range(n):
        if i % 2 == 0 and i % 3 == 0:
            c += 1
        if i % 5 == 0 or i % 7 == 0:
            c += 10
    return c
print(andor(1000))

func lcg(n):
    let x = 12345
    let h = 0
    for i in range(n):
        x = (x * 1103515245 + 12345) % 2147483648
        h = (h + x) % 1000000007
    return h
print(lcg(20000))

func shadow(n):
    let r = 0
    for i in range(n):
        let t = i * 2
        if t > 100:
            let t = 5
            r += t
        r += t
    return r
print(shadow(200))

func intfloat(n):
    let x = 0
    for i in range(n):
        if i == 50:
            x = 0.5
        x = x + 1
    return x
print(intfloat(200))

func strs(n):
    let s = 0
    let names = ["a", "bb", "ccc"]
    for i in range(n):
        s += len(names[i % 3])
    return s
print(strs(300))
