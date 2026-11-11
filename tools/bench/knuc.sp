let letters = "ACGT"
let seed = 5
let parts = []
for i in range(300000):
    seed = (seed * 16807) % 2147483647
    parts.append(letters[seed % 4:seed % 4 + 1])
let dna = parts.join("")
func count(s, k):
    let t = {}
    let n = len(s) - k + 1
    for i in range(n):
        let key = s.slice(i, i + k)
        t[key] = (t[key] ?? 0) + 1
    return t
let total = 0
for k in [1, 2, 3, 4, 6, 8]:
    let t = count(dna, k)
    let best = 0
    for key, v in t:
        if v > best:
            best = v
    total += best + len(t)
print(total, count(dna, 4)["ACGT"])
