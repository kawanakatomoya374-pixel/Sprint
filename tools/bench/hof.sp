let a = []
for i in range(100000):
    a.append(i % 1000)
let total = 0
for r in range(25):
    let b = a.map(func(x): x * 3 + r)
    let c = b.filter(func(x): x % 2 == 0)
    total += c.reduce(func(acc, x): acc + x, 0)
print(total)
