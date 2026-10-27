# string-key table access and string concatenation in compiled loops (hget/hset/hconcat),
# including every shape the helpers decline so the interpreter must run the instruction.
let t = {}
let s = 0
for i in range(3000):
    t["k" .. (i % 97)] = i
    s += t["k" .. (i % 97)]
print(s, len(t))

# missing key, hit, miss
let m = 0
let h = {"a": 1, "b": 2}
for i in range(2000):
    let k = "a"
    if i % 3 == 0:
        k = "b"
    m += h[k]
print(m)
try:
    for i in range(2000):
        let k = "a"
        if i == 1500:
            k = "zz"
        m += h[k]
catch e:
    print("missing", m)

# mixed operand types for concat: int, float, bool, nil, string
let parts = []
for i in range(600):
    let v = i
    if i % 5 == 1:
        v = i + 0.5
    if i % 5 == 2:
        v = "s"
    if i % 5 == 3:
        v = true
    if i % 5 == 4:
        v = nil
    try:
        parts.append("x" .. v .. "y")
    catch e:
        parts.append("err")
print(len(parts), parts[0], parts[1], parts[2], parts[3], parts[4], parts[599])

# receivers that are not tables: arrays, strings, and a receiver whose type flips mid-loop
let arr = [10, 20, 30]
let str = "hello"
let r = 0
for i in range(3000):
    r += arr[i % 3]
    if str[i % 5] == "l":
        r += 1
print(r)

let box = {"v": 1}
let flip = box
let z = 0
try:
    for i in range(3000):
        if i == 2000:
            flip = [1, 2, 3]
        z += flip["v"]
catch e:
    print("flip", z)

# keys of other types: int, float, bool in a hash table; nil key and nil value
let g = {}
for i in range(500):
    g[i] = i * 2
    g[i + 0.5] = i
    g[i % 2 == 0] = i
let gs = 0
for i in range(500):
    gs += g[i] + g[i + 0.5]
print(gs, g[true], g[false])
try:
    for i in range(100):
        let k = i
        if i == 50:
            k = nil
        g[k] = 1
catch e:
    print("nilkey")

# overwriting, growing past the first rehash, and long keys (> 48 bytes: hash computed lazily)
let big = {}
let long = "0123456789012345678901234567890123456789012345678901234567890123456789"
for i in range(4000):
    big[long .. (i % 300)] = i
    big["q" .. i] = i
let bs = 0
for i in range(300):
    bs += big[long .. i]
print(bs, len(big))

# GC pressure: temporaries are produced every iteration
let keep = {}
for i in range(20000):
    let k = "tmp" .. i .. "_" .. (i * 7)
    if i % 100 == 0:
        keep[k] = i
print(len(keep))

# deleting entries between compiled accesses
let d = {}
for i in range(1000):
    d["d" .. i] = i
let dc = 0
for i in range(1000):
    if i % 2 == 0:
        delete(d, "d" .. i)
for i in range(1000):
    try:
        dc += d["d" .. i]
    catch e:
        dc -= 1
print(dc, len(d))
