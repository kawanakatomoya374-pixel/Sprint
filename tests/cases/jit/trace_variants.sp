func is_alpha(c):
    return (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or c == 95
func is_digit(c):
    return c >= 48 and c <= 57
func classify(s):
    let a = 0
    let d = 0
    let o = 0
    for i in range(len(s)):
        let c = s[i]
        if is_alpha(c):
            a += 1
        elif is_digit(c):
            d += 1
        else:
            o += 1
    return [a, d, o]
let text = ("abc_XYZ" .. "0123456789" .. "  ;;..").repeat(400)
let r = [0, 0, 0]
for k in range(30):
    r = classify(text)
print(r)
let mixed = "a1 b2 c3 d4 e5 ;;; x9".repeat(300)
for k in range(30):
    r = classify(mixed)
print(r)
func and_or(n):
    let t = 0
    for i in range(n):
        let x = i % 11
        if (x > 2 and x < 6) or x == 9:
            t += 1
        elif x == 0 or x == 10:
            t += 100
        else:
            t += 10000
    return t
print(and_or(100000))
func values(n):
    let t = 0
    for i in range(n):
        let ok = (i % 3 == 0) and (i % 5 == 0)
        if ok:
            t += 1
        let alt = (i % 7 == 0) or (i % 11 == 0)
        if alt:
            t += 2
    return t
print(values(100000))
func phases(n):
    let t = 0
    for i in range(n):
        if i < 20000:
            t += 1
        elif i < 50000:
            t += 2
        elif i < 70000:
            t += 3
        else:
            t += 4
    return t
print(phases(100000))
