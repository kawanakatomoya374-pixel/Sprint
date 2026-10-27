import math
import gc

# member lookups go through a cache keyed on (table, name); it must survive rebuilds, deletes and GC
let t = {a: 1, b: 2, c: 3}
func get_b(x):
    return x.b
let s = 0
for i in range(50):
    s += get_b(t)
print(s)
t.b = 10
print(get_b(t))
t["z"] = 1
for i in range(40):
    t["k" .. to_string(i)] = i      # forces rebuilds of the entry array
print(get_b(t), t.a, t.c)
t.b = nil
print(get_b(t))
t.b = 77
print(get_b(t))
for i in range(5):
    gc.collect()
    print(get_b(t), math.sqrt(16.0), math.floor(2.5))
let u = {b: "other"}
print(get_b(u), get_b(t), get_b(u))
let objs = []
for i in range(300):
    objs.append({b: i})
let total = 0
for o in objs:
    total += get_b(o)
print(total)
