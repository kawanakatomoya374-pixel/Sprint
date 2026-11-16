let seed = 7
func rnd():
    seed = (seed * 1664525 + 1013904223) % 4294967296
    return seed % 1000001
let a = []
for i in range(300000):
    a.append(rnd())
a.sort()
let b = a.map(func(x): x * 2).filter(func(x): x % 3 == 0)
let s = b.reduce(func(acc, x): acc + x, 0)
a.sort(func(x, y): y - x)
print(a[0], len(b), s)
