# for-in over tables in compiled loops (tnext): success, break/continue, modification during iteration, type change
let t = {}
for i in range(2000):
    t["k" .. i] = i
let s = 0
let ks = 0
for r in range(5):
    for k, v in t:
        s += v
    for k in t:
        ks += len(k)
print(s, ks)
# mixed key types, nested loops, break/continue
let m = {}
m[1] = "a"
m["two"] = 2
m[3.5] = "c"
m[true] = 4
let n = 0
for r in range(500):
    for k, v in m:
        if k == 1:
            continue
        n += 1
        if r == 400:
            break
print(n)
# modification during iteration must raise the same error
let e = {"a": 1, "b": 2, "c": 3}
let cnt = 0
try:
    for r in range(300):
        for k, v in e:
            cnt += 1
            if r == 250 and k == "a":
                e["z" .. r] = 1
catch err:
    print("modified", cnt)
# the iterated value changes type between runs of the loop
let it = {"x": 1, "y": 2}
let tot = 0
for r in range(400):
    let src = it
    if r == 300:
        src = [10, 20]
    for a in src:
        tot += 1
print(tot)
# a nested table value and an empty table
let nest = {"p": {"q": 1}, "r": {}}
let q = 0
for r in range(300):
    for k, v in nest:
        for k2 in v:
            q += 1
print(q)
let emp = {}
let z = 0
for r in range(500):
    for k in emp:
        z += 1
print(z)
