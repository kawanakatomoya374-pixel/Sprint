# fused ops: top <op> local, x % m == k tests; every result must equal the unfused (--no-quicken) run
func f_add(a, b):
    return a * 2 + b
func f_sub(a, b):
    return a * 2 - b
func f_mul(a, b):
    return a + 1 * a * b
func f_div(a, b):
    return a * 3 / b
func even(n):
    if n % 2 == 0:
        return "even"
    return "odd"
func m3(n):
    if n % 3 != 1:
        return "not1"
    return "is1"
func mbig(n):
    if n % 1000003 == 5:
        return "five"
    return "other"
let out = []
for p in [[3, 4], [1.5, 2.5], [3, 2.5], [2.5, 3], [9223372036854775807, 1], [-5, 7]]:
    for fn in [f_add, f_sub, f_mul]:
        try:
            out.append(fn(p[0], p[1]))
        catch e:
            out.append(e.kind)
for p in [[3.0, 2.0], [3.0, 0.0], [3, 2], [3.0, 2], [6, 3]]:
    try:
        out.append(f_div(p[0], p[1]))
    catch e:
        out.append(e.kind)
for n in [0, 1, 2, 3, 4, -1, -2, -3, 7, 1000008, 5, -999998]:
    out.append(even(n) .. m3(n) .. mbig(n))
out.append(even(2.0))
out.append(even(7.5))
for v in out:
    print(v)
