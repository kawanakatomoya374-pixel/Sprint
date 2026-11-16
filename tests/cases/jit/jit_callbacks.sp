# callbacks called from native code (map / filter / reduce / sort comparators / find / any / all) run compiled code directly; the results,
# errors raised inside callbacks, callbacks that leave compiled code (wrong argument types) and deep re-entry must equal the interpreter's
let a = []
for i in range(2000):
    a.append(i % 37)
let tot = 0
for r in range(40):
    let b = a.map(func(x): x * 3 + r)
    let c = b.filter(func(x): x % 2 == 0)
    tot += c.reduce(func(acc, x): acc + x, 0)
    tot += len(a.filter(func(x): x > 20))
print(tot)
let words = ["pear", "fig", "banana", "kiwi", "apple", "cherry", "date"]
let lens = 0
for r in range(60):
    let s = words.map(func(w): len(w))
    lens += s.reduce(func(x, y): x + y, 0)
print(lens)
let nums = []
for i in range(300):
    nums.append((i * 7919) % 1000)
let sorted_ok = 0
for r in range(20):
    let c = nums.map(func(x): x)
    c.sort(func(x, y): y - x)
    sorted_ok += c[0] - c[299]
print(sorted_ok)
# a callback that sees different argument types: compiled for ints first, then floats and strings
let mixed = [1, 2, 3, 4.5, "x", 6, 7.25, nil, 9]
let kinds = 0
for r in range(80):
    let k = mixed.map(func(v): to_string(v))
    kinds += len(k.filter(func(s): len(s) > 1))
print(kinds)
# errors inside a callback propagate after the callback was compiled
func risky(x):
    if x == 999:
        throw error("Boom", "x is " .. x)
    return x + 1
let ok = 0
for r in range(200):
    ok += [1, 2, 3].map(risky).reduce(func(a, b): a + b, 0)
try:
    [1, 999, 3].map(risky)
catch e:
    print(e.kind, e.message)
print(ok)
# callbacks that call other natives and recurse through map
func depth(n):
    if n == 0:
        return 1
    return [n].map(func(x): depth(x - 1) + 1)[0]
let ds = 0
for r in range(50):
    ds += depth(20)
print(ds)
print(a.find(func(x): x == 30), a.any(func(x): x > 36), a.all(func(x): x < 37), a.any(func(x): x > 99))
