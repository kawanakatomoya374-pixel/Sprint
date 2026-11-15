func compress(data):
    let dict = {}
    for i in range(256):
        dict["c" .. to_string(i)] = i
    let nxt = 256
    let out = []
    let w = ""
    for i in range(len(data)):
        let c = data.slice(i, i + 1)
        let wc = w .. c
        let key = "w" .. wc
        if (dict[key] ?? -1) >= 0 or (len(wc) == 1):
            w = wc
        else:
            let code = 0
            if len(w) == 1:
                code = w[0]
            else:
                code = dict["w" .. w]
            out.append(code)
            dict[key] = nxt
            nxt += 1
            w = c
    if len(w) > 0:
        out.append(w[0] if len(w) == 1 else dict["w" .. w])
    return out
let letters = "abcdefgh"
let seed = 17
let parts = []
for i in range(60000):
    seed = (seed * 16807) % 2147483647
    parts.append(letters.slice(seed % 8, seed % 8 + 1))
let text = parts.join("")
let total = 0
let last = 0
for r in range(3):
    let o = compress(text)
    total += len(o)
    last = o[len(o) - 1]
print(total, last)
