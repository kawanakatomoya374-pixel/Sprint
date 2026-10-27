let words = ["pear", "fig", "apple", "kiwi", "date"]
let counts = {"pear": 2, "fig": 5, "apple": 2, "kiwi": 5, "date": 1}
words.sort(func(a, b): counts[a] > counts[b] or (counts[a] == counts[b] and a < b))
print(words)
let xs = [5, 3, 9, 1, 3]
xs.sort(func(a, b): a > b)
print(xs)
let pairs = [[1, "b"], [0, "x"], [1, "a"], [0, "y"]]
pairs.sort(func(p, q): p[0] < q[0])
print(pairs)
let big = []
for i in range(2000):
    big.append((i * 7919) % 2003)
big.sort(func(a, b): a < b)
print(big[0], big[1999], len(big))
func bad(a, b):
    throw error("CmpErr", "no")
let ys = [3, 2, 1]
try:
    ys.sort(bad)
catch e:
    print(e.kind, ys)
let zs = [3, 2, 1]
func mut(a, b):
    zs.append(0)
    return a < b
try:
    zs.sort(mut)
catch e:
    print(e.kind, len(zs) > 3)
