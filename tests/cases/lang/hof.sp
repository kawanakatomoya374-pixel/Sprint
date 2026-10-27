let a = [1, 2, 3, 4, 5]
print(a.map(func(x): x * x))
print(a.filter(func(x): x % 2 == 1))
print(a.reduce(func(acc, x): acc + x, 0))
print(a.any(func(x): x > 4), a.all(func(x): x > 1), a.find(func(x): x > 2), a.find(func(x): x > 9))
let sum = 0
func add(x):
    sum += x
a.each(add)
print(sum)
print(["b", "a"].map(func(s): s.upper()).join("-"))
try:
    a.map(func(x): 1 // 0)
catch e:
    print(e.kind)
try:
    a.map(5)
catch e:
    print(e.kind)
let big = []
for i in range(3000):
    big.append(i)
let sq = big.map(func(i): [i])
print(len(sq), sq[2999][0])
import gc
func churn(i):
    gc.collect()
    return [i, "s" .. i]
let ch = big.slice(0, 50).map(churn).filter(func(p): p[0] % 2 == 0)
print(len(ch), ch[3])
print(big.slice(0, 20).reduce(func(acc, i): acc .. i, ""))
