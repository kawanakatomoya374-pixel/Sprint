# table literals and type() inside hot functions (JIT helpers); duplicate keys, non-string keys and a nil key (an error) behave as in the interpreter
func mk(i):
    return {"a": i, "b": [i, "s"], "c": "x", "a2": i * 2}

func dup(i):
    return {"k": i, "k": i + 1, 7: "seven", true: i}

func kinds(v):
    if v == nil:
        return 0
    elif type(v) == "int":
        return 1
    elif type(v) == "string":
        return 2
    elif type(v) == "array":
        return 3
    elif type(v) == "table":
        return 4
    return 5

let acc = 0
for i in range(2000):
    let t = mk(i)
    acc += kinds(t) + kinds(t["b"]) + kinds(t["c"]) + kinds(t["a"]) + kinds(nil) + kinds(1.5)
    let d = dup(i)
    acc += d["k"] + len(d)
print(acc)
func badkey(i):
    let k = nil
    if i == 1500:
        k = nil
    return {k: i}
let caught = 0
for i in range(2000):
    try:
        let t = badkey(i)
        if len(t) > 5:
            caught += 100
    catch e:
        caught += 1
print(caught)
