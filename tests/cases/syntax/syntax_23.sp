# 2.3 syntax: in / not in, chained comparison, ?. ?[ ??=, table shorthand,
# destructuring for, multiple assignment, if let / while let, raw strings
print(2 in [1, 2], "a" not in {a: 1}, "ell" in "hello", 5 not in [1])
print(1 < 2 < 3, 3 > 2 > 2, 1 < 2 <= 2 < 5, 1 == 1 != 2)

let n = 0
func tick():
    n += 1
    return n
print(0 < tick() < 5, n)
print(5 < tick() < tick(), n)

let x = 1
let y = 2
print({x, y}, {x, y: 5})

for [a, b] in [[1, 2], [3, 4]]:
    print(a + b)
for {p, q: r} in [{p: 1, q: 2}]:
    print(p, r)
for [a, b] in [[1, 2], [3, 4], [5, 6]] if a > 1:
    print(a, b)
print([a * b for [a, b] in [[1, 2], [3, 4]] if a in [3]])

let t = {a: {b: [10, 20]}}
print(t?.a?.b?[1], t?.z?.b, nil?.x, nil?[0])
let s = nil
print(s?.slice(1), "abc"?.slice(1))
let calls = 0
func side():
    calls += 1
    return 1
print(nil?[side()], calls)

let cfg = {}
cfg.x ??= 3
cfg.x ??= 4
cfg["y"] ??= 5
let z = nil
z ??= "d"
z ??= "e"
print(cfg, z)

let u = 1
let v = 2
u, v = v, u
print(u, v)
let arr = [0, 0, 0]
arr[0], arr[2] = 7, 9
print(arr)
u, v = [10, 20]
print(u, v)

func find(k):
    return {a: 1, b: false}[k]
if let w = find("a"):
    print("got", w)
else:
    print("none")
if let w = find("q"):
    print("got", w)
elif u == 10:
    print("elif")
if let w = find("b"):
    print("false is not nil:", w)
let q = [3, 2, 1]
while let e = (q.pop() if len(q) > 0 else nil):
    print(e)
print(len(q))

print(r"a\nb", r'c\td', r"""x\y""")
try:
    print(1 in 5)
catch e:
    print(e.kind)
try:
    print(nil?.x.y.z)
catch e:
    print(e.kind)
