let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
func encode(s, chars):
    let out = []
    let n = len(s)
    let i = 0
    while i + 2 < n:
        let v = (s[i] << 16) | (s[i + 1] << 8) | s[i + 2]
        out.append(chars[v >> 18])
        out.append(chars[(v >> 12) & 63])
        out.append(chars[(v >> 6) & 63])
        out.append(chars[v & 63])
        i += 3
    return out.join("")
let chars = []
for i in range(64):
    chars.append(alphabet[i:i + 1])
let seed = 99
let parts = []
for i in range(60000):
    seed = (seed * 16807) % 2147483647
    parts.append(to_string(seed))
let data = parts.join(",")
let total = 0
let last = ""
for r in range(12):
    last = encode(data, chars)
    total += len(last)
print(total, last.slice(0, 24))
