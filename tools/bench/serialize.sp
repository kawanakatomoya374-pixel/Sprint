func ser(v, out):
    if v == nil:
        out.append("nil")
    elif type(v) == "int":
        out.append(to_string(v))
    elif type(v) == "string":
        out.append("\"")
        out.append(v)
        out.append("\"")
    elif type(v) == "array":
        out.append("[")
        for i in range(len(v)):
            if i > 0:
                out.append(",")
            ser(v[i], out)
        out.append("]")
    else:
        out.append("{")
        let first = true
        for k, x in v:
            if not first:
                out.append(",")
            first = false
            out.append(k)
            out.append(":")
            ser(x, out)
        out.append("}")
func build(d, seed):
    if d == 0:
        return seed
    return {"a": build(d - 1, seed + 1), "b": [seed, "s" .. to_string(seed), build(d - 1, seed + 2)], "c": "x"}
let tree = build(14, 1)
let total = 0
for r in range(4):
    let out = []
    ser(tree, out)
    total += len(out.join(""))
print(total)
