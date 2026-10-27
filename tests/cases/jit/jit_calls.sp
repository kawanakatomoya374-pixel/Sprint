import math
func fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

func fibf(n):
    if n < 2:
        return n * 1.5
    return fibf(n - 1) + fibf(n - 2)

func poly(x):
    return x + 1

func deep(n):
    if n == 0:
        return 0
    return 1 + deep(n - 1)

func boom(n):
    if n == 0:
        return 1 // n
    return boom(n - 1) + 1

let g = 0
func bump(k):
    g = g + k
    return g

func mk():
    let c = 0
    func inc(d):
        c += d
        return c
    return inc

func tail(a, b):
    return a * 2 + b

let total = 0
for i in range(300):
    total += fib(10) + math.floor(fibf(8))
print(total)
print(fib(20), fibf(10))
for i in range(100):
    total += poly(i)
    total += poly(i + 0.5)
print(total)
print(deep(500))
let r = 0
for i in range(200):
    r += bump(i)
print(r, g)
let f = mk()
let s = 0
for i in range(500):
    s += f(i)
print(s, f(1))
let acc = 0
for i in range(1000):
    acc += tail(i, i + 1)
print(acc)
try:
    boom(30)
catch e:
    print("caught", e.message)
for i in range(60):
    try:
        boom(i % 5)
    catch e:
        acc += 1
print(acc)
