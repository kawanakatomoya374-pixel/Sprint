let base = "a".repeat(2000)
let s1 = base .. "X"
let s2 = base .. "Y"
let s3 = s1 .. "Z"
let s4 = s1 .. "W"
print(len(s1), len(s2), len(s3), len(s4))
print(s1[2000], s2[2000], s3[2001], s4[2001])
print(s1 == s2, s3 == s4, s3 == (base .. "XZ"), s4 == (base .. "XW"))
let acc = ""
for i in range(5000):
    acc = acc .. "ab"
    if i == 2500:
        let keep = acc
        acc = acc .. "-"
        acc = keep .. "+"
print(len(acc), acc[5000], acc[9999])
let branch = acc
let b1 = branch .. "1"
let b2 = branch .. "2"
let b3 = b1 .. "3"
print(b1[len(b1) - 1], b2[len(b2) - 1], b3[len(b3) - 2], len(branch))
let t = {}
t[b1] = 1
t[b2] = 2
t[b3] = 3
print(t[b1], t[b2], t[b3], t[branch .. "1"], t[branch .. "2"])
print(b1.contains("ab1"), b3.starts_with("abab"), b3.ends_with("13"), b1.find("1"))
print(b1.upper()[len(b1) - 1], b1.slice(0, 4), len(b1.split("1")))
let parts = []
for i in range(200):
    parts.append(b3 .. i)
print(len(parts.join(",")), len(parts[199]))
let n = 0
for i in range(len(b3)):
    if b3[i] == 97:
        n += 1
print(n)
let u = ""
for i in range(3000):
    u = u .. 7 .. ","
print(len(u), u[0], u[1], u[5999])
func build(k):
    let r = ""
    for i in range(k):
        r = r .. "xyz"
    return r
let r1 = build(1000)
let r2 = build(1000)
print(r1 == r2, len(r1), r1 .. "!" == r2 .. "!")
print(f"{r1}|{len(r1)}"[3000], len(f"{b3}") == len(b3))
