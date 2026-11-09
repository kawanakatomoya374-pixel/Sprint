func fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)
func tak(x, y, z):
    if y < x:
        return tak(tak(x - 1, y, z), tak(y - 1, z, x), tak(z - 1, x, y))
    return z
func ack(m, n):
    if m == 0:
        return n + 1
    if n == 0:
        return ack(m - 1, 1)
    return ack(m - 1, ack(m, n - 1))
func fact(n):
    if n <= 1:
        return 1
    return n * fact(n - 1)
func sumto(n):
    if n == 0:
        return 0
    return n + sumto(n - 1)
func pw(a, n):
    if n == 0:
        return 1
    return a * pw(a, n - 1)
print(fib(24))
print(fib(27))
print(tak(18, 12, 6))
print(ack(2, 300))
print(ack(3, 5))
print(fact(15))
print(fact(20))
try:
    print(fact(25))
catch err:
    print(err.kind)
print(sumto(1000))
print(sumto(900))
print(pw(3, 30))
try:
    print(pw(3, 60))
catch err:
    print(err.kind)
print(fib(10) + fib(11) * 2)
print(fib(30))
let r = 0
for i in range(30):
    r += fib(15)
print(r)
