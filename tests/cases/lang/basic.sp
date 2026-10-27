func fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

let xs = [3, 1, 2]
xs.sort()
print(fib(20), xs, len("héllo"))
let t = {"a": 1, "b": [1, 2]}
print(t, 7 / 2, 7 // 2, 2 ** 10, 1 < 1, 1 <= 1)
try:
    let z = [1][5]
catch e:
    print("caught", e.kind)
let s = 0
for i in range(5):
    s += i
print(s, "a,b,c".split(","), "x".repeat(3))
