# s.slice(a, b) and t[k] = t[k] + 1 inside hot loops (JIT helpers): in-range, empty, multi-byte, and error cases leave to the interpreter
func count(s, k):
    let t = {}
    for i in range(len(s) - k + 1):
        let key = s.slice(i, i + k)
        t[key] = (t[key] ?? 0) + 1
    return t
let dna = "ACGTTGCAACGTAGCTAGCTAGGATCCATCGATCGATCGTAGCTAGCTAGCATCGA"
let big = ""
for r in range(40):
    big = big .. dna
let t1 = count(big, 3)
let t2 = count(big, 5)
print(len(t1), len(t2), t1["ACG"], t2["GATCG"])
let u = "añb日本語cd"
let parts = []
for i in range(300):
    parts.append(u.slice(0, 3))
    parts.append(u.slice(3, 3))
    parts.append(u.slice(0, len(u)))
print(parts[0], parts[1] == "", parts[2], len(parts))
let ok = 0
for i in range(400):
    let r = dna.slice(i % 10, i % 10 + 4)
    if r == "ACGT":
        ok += 1
print(ok)
let tt = {}
for i in range(1000):
    let k = "k" .. to_string(i % 7)
    tt[k] = (tt[k] ?? 0) + 1
    if i == 500:
        tt["k3"] = nil
print(len(tt), tt["k0"], tt["k3"])
