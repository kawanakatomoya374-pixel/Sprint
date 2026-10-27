# pure math natives and len() called from compiled loops through a helper (hnat): success, error and type-change exits
import math
let s = 0
let f = 0.0
for i in range(100000):
    s += math.abs(-i) + math.floor(i / 3) + math.max(i, 5, 7) + math.min(i, 9) + math.clamp(i, 10, 20)
    f += math.abs(-0.5 * i) + math.round(i * 0.37) + math.atan2(i, 3.0) + math.log(i + 1)
print(s, f)
let e = 0
for i in range(300):
    try:
        let v = i
        if i == 150:
            v = "x"
        s += math.abs(v)
    catch err:
        e += 1
print(e, s)
try:
    let m = math.int_min
    for i in range(500):
        s += math.abs(m + (i // 499))
catch err:
    print("overflow", s)
# len of strings, tables, arrays, and a non-container mid-loop
let strs = ["a", "bb", "ccc"]
let tb = {"x": 1, "y": 2}
let ar = [1, 2, 3, 4]
let ls = 0
for i in range(3000):
    ls += len(strs[i % 3]) + len(tb) + len(ar) + len("hello")
print(ls)
let bad = 0
try:
    for i in range(3000):
        let o = ar
        if i == 2500:
            o = 5
        bad += len(o)
catch err:
    print("len error", bad)
