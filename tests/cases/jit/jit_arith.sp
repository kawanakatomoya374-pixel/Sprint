import math
# Hot loops are compiled by the JIT; every result and every error must equal the interpreter's.
func ints(n):
    let s = 0
    let t = 1
    for i in range(n):
        s += i * 3 - i // 2 + i % 7
        t = (t * 31 + i) % 1000003
        s -= (i - n) // 3 + (i - n) % 5
    return [s, t]
print(ints(5000))

func negdiv(n):
    let a = 0
    let b = 0
    let c = 0
    for i in range(-n, n):
        a += i // 3 + i // 7 + i // 8 + i // 10 + i // 641 + i // 2147483647
        b += i % 3 + i % 7 + i % 8 + i % 10 + i % 641 + i % 2147483647
        c += i // -3 + i % -5
    return [a, b, c]
print(negdiv(3000))

func big():
    let x = 9223372036854775000
    let s = 0
    for i in range(300):
        s += (x // 7 + x % 7 + (x - i) // 641 + (x - i) % 641 + (0 - x + i) // 641 + (0 - x + i) % 641) % 1000003
    return s
print(big())

func flt(n):
    let x = 0.5
    let y = 1.0
    let z = 0
    for i in range(n):
        x = x * 1.0001 + y / 3.0 - i * 0.25
        y = y - x * 0.0001 + 2
        z += i / 4 + x // 1.0 if false else i / 4
    return [x, y, z]
print(flt(2000))

func mixed(n):
    let k = 0
    let f = 0.0
    for i in range(n):
        f += i
        f = f * 2 - i
        f = f / 2 + 1
        if f > i * 1.5:
            k += 1
        if i < f:
            k += 2
        if i == 7:
            k += 100
        if f != f:
            k += 1000
    return [k, f]
print(mixed(3000))

func nans(n):
    let nan = math.nan
    let c = 0
    for i in range(n):
        if nan < 1.0:
            c += 1
        if nan >= 1.0:
            c += 10
        if nan == nan:
            c += 100
        if nan != nan:
            c += 1000
        if 1.0 <= nan:
            c += 10000
    return c
print(nans(100))

func exact(n):
    let c = 0
    let big = 9007199254740993
    let f = 9007199254740992.0
    for i in range(n):
        if big > f:
            c += 1
        if big == f:
            c += 10
        if f < big:
            c += 100
    return c
print(exact(100))

func overflow(n):
    let x = 4611686018427387904
    let r = 0
    for i in range(n):
        r += 1
        x = x + x
    return r
try:
    print(overflow(100))
catch e:
    print("caught", e.kind)

func mulovf(n):
    let x = 3
    for i in range(n):
        x = x * 3
    return x
try:
    print(mulovf(100))
catch e:
    print("caught", e.kind)

func divzero(n):
    let s = 0
    for i in range(n):
        s += 100 // (50 - i)
    return s
try:
    print(divzero(100))
catch e:
    print("caught", e.kind)

func modzero(n):
    let s = 0
    for i in range(n):
        s += 100 % (60 - i)
    return s
try:
    print(modzero(100))
catch e:
    print("caught", e.kind)

func fdivzero(n):
    let s = 0.0
    for i in range(n):
        s += 10.0 / (30 - i)
    return s
try:
    print(fdivzero(100))
catch e:
    print("caught", e.kind)

func neg(n):
    let s = 0
    let f = 0.5
    for i in range(n):
        s += -i
        f = -f + 0.25
    return [s, f]
print(neg(1001))
