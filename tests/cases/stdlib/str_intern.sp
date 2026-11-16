# short strings made from bytes are shared by content; the sharing is invisible to programs and must survive collections:
# dead strings leave the table, live ones keep working as table keys
import gc
let dna = ""
let seed = 7
let parts = []
for i in range(4000):
    seed = (seed * 16807) % 2147483647
    parts.append("ACGT".slice(seed % 4, seed % 4 + 1))
dna = parts.join("")
func count(s, k):
    let t = {}
    for i in range(len(s) - k + 1):
        let key = s.slice(i, i + k)
        t[key] = (t[key] ?? 0) + 1
        if i % 700 == 0:
            gc.collect()
    return t
let keep = count(dna, 3)
for r in range(6):
    let t = count(dna, 2 + r % 3)
    gc.collect()
let again = count(dna, 3)
print(len(keep), len(again), keep["ACG"] == again["ACG"], keep["TTT"] ?? 0)
let n = 0
for k, v in keep:
    n += v
print(n)
# equal contents compare equal whichever way the strings were made; unequal ones never do
let a = "item" .. 12
let b = "item12".slice(0, 6)
let c = "item1".slice(0, 5) .. "2"
print(a == b, b == c, a == "item13", len(a), a.upper(), a.slice(1, 3) == "te")
# many distinct short strings, then a collection, then the same contents again
let seen = {}
for i in range(20000):
    seen[to_string(i % 5000)] = i
gc.collect()
let s2 = 0
for i in range(5000):
    s2 += seen[to_string(i)]
print(len(seen), s2)
