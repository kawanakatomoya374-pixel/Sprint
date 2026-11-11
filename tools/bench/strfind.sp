let seed = 21
let parts = []
for i in range(120000):
    seed = (seed * 16807) % 2147483647
    parts.append("w" .. to_string(seed % 997))
let text = parts.join(" ")
func count_sub(s, sub):
    let c = 0
    let p = s.find(sub, 0)
    while p >= 0:
        c += 1
        p = s.find(sub, p + len(sub))
    return c
let total = 0
for i in range(300):
    total += count_sub(text, "w12")
    total += count_sub(text, "99 w")
let up = text.upper()
let rep = text.replace("w1", "WW")
print(total, len(up), len(rep), up.slice(0, 10))
