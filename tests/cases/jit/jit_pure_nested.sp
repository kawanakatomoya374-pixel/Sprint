# pure recursive integer functions with nested self calls (tak / ackermann shaped), overflow (falls back), three parameters
func f(n):
    if n < 2:
        return n
    return f(n - 1) * 3 + f(n - 2) - 1
func ov(n):
    if n == 0:
        return 1
    return ov(n - 1) * 1000003
func g(a, b, c):
    if a <= 0:
        return b - c
    return g(a - 1, b + 2, c - 3) + g(a - 1, c, b) - 7
func tak(x, y, z):
    if y >= x:
        return z
    return tak(tak(x - 1, y, z), tak(y - 1, z, x), tak(z - 1, x, y))
func ack(m, n):
    if m == 0:
        return n + 1
    if n == 0:
        return ack(m - 1, 1)
    return ack(m - 1, ack(m, n - 1))
print(f(24), ov(2), g(9, 5, 4))
print(tak(18, 12, 6), ack(2, 30), ack(3, 5))
print(ov(3))
try:
    print(ov(40))
catch e:
    print("overflow", e.kind)
