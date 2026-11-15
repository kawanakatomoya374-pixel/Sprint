let vals = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1]
let syms = ["M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"]
func roman(n):
    let out = ""
    for i in range(13):
        while n >= vals[i]:
            out = out .. syms[i]
            n -= vals[i]
    return out
func unroman(s):
    let total = 0
    let prev = 0
    let i = len(s) - 1
    while i >= 0:
        let c = s[i]
        let v = 0
        if c == 73:
            v = 1
        elif c == 86:
            v = 5
        elif c == 88:
            v = 10
        elif c == 76:
            v = 50
        elif c == 67:
            v = 100
        elif c == 68:
            v = 500
        else:
            v = 1000
        if v < prev:
            total -= v
        else:
            total += v
            prev = v
        i -= 1
    return total
let acc = 0
for r in range(14):
    for n in range(1, 4000):
        acc += unroman(roman(n))
print(acc)
