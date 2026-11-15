func parse_array(s, pos, out):
    # parses [n,n,...] of non-negative ints starting after "["; returns the position after "]"
    let n = len(s)
    let cur = 0
    let have = false
    while pos < n:
        let c = s[pos]
        if c >= 48 and c <= 57:
            cur = cur * 10 + (c - 48)
            have = true
        elif c == 44:
            out.append(cur)
            cur = 0
            have = false
        elif c == 93:
            if have:
                out.append(cur)
            return pos + 1
        pos += 1
    return pos
let parts = []
let seed = 29
for i in range(120000):
    seed = (seed * 16807) % 2147483647
    parts.append(to_string(seed % 1000000))
let text = "[" .. parts.join(",") .. "]"
let total = 0
for r in range(6):
    let out = []
    parse_array(text, 1, out)
    let s = 0
    for x in out:
        s += x
    total += s % 1000003 + len(out)
print(total)
