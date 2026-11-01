# floor division and modulo inside trace-compiled loops: every sign combination, a zero divisor (error), a -1 divisor
# and INT64_MIN must behave exactly like the interpreter
func sums(n, d):
    let a = 0
    let b = 0
    let i = 0 - n
    while i < n:
        a = a + i // d
        b = b + i % d
        i += 1
    return [a, b]
print(sums(3000, 7))
print(sums(3000, 0 - 7))
print(sums(3000, 1))
print(sums(3000, 2))
print(sums(3000, 0 - 2))
print(sums(3000, 1000003))

func chain(n):
    let x = 12345
    let i = 0
    while i < n:
        x = (x * 31 + i) % 1000003
        x = x // 3 + x % 5
        i += 1
    return x
print(chain(100000))

# the divisor walks towards -1 and the loop stops there: the trace compiled earlier must deoptimise at d == -1 and let the
# interpreter finish the iteration
func toward_minus_one(n):
    let acc = 0
    let d = 0 - n
    let i = 0
    while i < n:
        acc = acc + (i * 1000) // d + (i * 1000) % d
        d += 1
        i += 1
    return acc
print(toward_minus_one(5000))

# the divisor reaches zero: ArithmeticError, raised by the interpreter after the trace left through its deopt exit
func toward_zero(n, lim):
    let acc = 0
    let d = n
    let i = 0
    while i < lim:
        acc = acc + (i + 7) // d
        d -= 1
        i += 1
    return acc
try:
    print(toward_zero(5000, 5001))
catch e:
    print(e.kind)

func min_div(n):
    let m = 0 - 9223372036854775807 - 1
    let d = 0 - n
    let acc = 0
    let i = 0
    while i < n:
        acc = acc + m // d % 1000
        d += 1
        i += 1
    return acc
try:
    print(min_div(5000))
catch e:
    print(e.kind)

# constant divisors: powers of two (shift / mask), other constants, and negative dividends
func consts_pow2(n):
    let a = 0
    let b = 0
    let i = 0 - n
    while i < n:
        a = a + i // 2 + i // 8 + i // 1
        b = b + i % 2 + i % 8 + i % 1
        i += 1
    return [a, b]
print(consts_pow2(5000))

func consts_other(n):
    let c = 0
    let d = 0
    let i = 0 - n
    while i < n:
        c = c + i // 10 + i // 1000003
        d = d + i % 10 + i % 1000003
        i += 1
    return [c, d]
print(consts_other(5000))
