func make(d):
    if d == 0:
        return [nil, nil]
    return [make(d - 1), make(d - 1)]
func check(t):
    if t[0] == nil:
        return 1
    return 1 + check(t[0]) + check(t[1])
let long_lived = make(17)
let total = 0
let d = 4
while d <= 16:
    let iters = 1 << (16 - d + 4)
    let c = 0
    for i in range(iters):
        c += check(make(d))
    total += c
    d += 4
print(total, check(long_lived))
